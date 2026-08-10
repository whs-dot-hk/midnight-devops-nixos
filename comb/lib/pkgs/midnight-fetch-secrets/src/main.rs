//! Boot-time secret delivery from GCP Secret Manager.
//!
//! Runs as root from `midnight-secrets.service`, before the node and db-sync
//! units. Everything it needs that is *not* secret — the project, the secret
//! IDs, the paths, the database endpoint — comes from a JSON config file
//! written by the NixOS module into the (world-readable) store. Everything it
//! fetches goes straight into 0600 files outside the store.
//!
//! Authentication is the instance's own service account, read from the GCE
//! metadata server; no key file exists on disk to leak.
//!
//! A missing or unreadable secret is not fatal: a validator's keys are often
//! added by hand after the first apply, and the node unit simply will not
//! start until they are there.

use std::ffi::CString;
use std::fs;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

const METADATA_TOKEN_URL: &str = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
const SECRET_MANAGER: &str = "https://secretmanager.googleapis.com/v1";

/// Written by the NixOS module. Absent secret IDs are null rather than empty.
#[derive(Deserialize)]
struct Config {
    project: String,
    env_file: PathBuf,
    user: String,
    group: String,
    node_type: String,
    secrets: Secrets,
    /// Validator seed-phrase files. Null for every other node type.
    secrets_dir: Option<PathBuf>,
    /// Where the libp2p key goes, and the tree to chown once it is written.
    network_dir: PathBuf,
    chains_dir: PathBuf,
    /// Null when no database credentials are wanted.
    db: Option<DbConfig>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Secrets {
    node: Option<String>,
    validator_keys: Option<String>,
    validator_seed_phrases: Option<String>,
    relay_keys: Option<String>,
    boot_node_keys: Option<String>,
    db: Option<String>,
}

#[derive(Deserialize)]
struct DbConfig {
    host: String,
    port: u16,
    name: String,
    user: String,
    ssl_mode: String,
    pgpass_file: PathBuf,
}

fn main() -> std::process::ExitCode {
    // Anything this process creates is for root and the node user only.
    unsafe { libc::umask(0o077) };

    let path = match std::env::args_os().nth(1) {
        Some(p) => PathBuf::from(p),
        None => {
            warn("usage: midnight-fetch-secrets <config.json>");
            return std::process::ExitCode::FAILURE;
        }
    };

    let cfg: Config = match fs::read(&path).map_err(|e| e.to_string()).and_then(|b| {
        serde_json::from_slice(&b).map_err(|e| e.to_string())
    }) {
        Ok(c) => c,
        Err(e) => {
            warn(&format!("cannot read config {}: {e}", path.display()));
            return std::process::ExitCode::FAILURE;
        }
    };

    match run(&cfg) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            warn(&e);
            std::process::ExitCode::FAILURE
        }
    }
}

fn run(cfg: &Config) -> Result<(), String> {
    let owner = Owner::resolve(&cfg.user, &cfg.group)?;
    let mut sm = SecretManager::new(&cfg.project);

    let is_validator = cfg.node_type == "validator";

    let mut node_key = String::new();
    let mut aura = String::new();
    let mut grandpa = String::new();
    let mut cross_chain = String::new();

    if let Some(payload) = sm.access(cfg.secrets.node.as_deref()) {
        node_key = field(&payload, "node-key");
        if is_validator {
            aura = field(&payload, "aura");
            grandpa = field(&payload, "grandpa");
            cross_chain = field(&payload, "crossChain");
        }
    }

    if is_validator {
        if let Some(p) = sm.access(cfg.secrets.validator_keys.as_deref()) {
            prefer(&mut node_key, field(&p, "node-key"));
            prefer(&mut aura, field(&p, "aura"));
            prefer(&mut grandpa, field(&p, "grandpa"));
            prefer(&mut cross_chain, field(&p, "crossChain"));
        }

        // Seed phrases win over everything else.
        if let Some(p) = sm.access(cfg.secrets.validator_seed_phrases.as_deref()) {
            prefer(&mut aura, field(&p, "aura"));
            prefer(&mut grandpa, field(&p, "grandpa"));
            prefer(&mut cross_chain, field(&p, "crossChain"));
        }
    }

    let node_key_override = match cfg.node_type.as_str() {
        "relay" => cfg.secrets.relay_keys.as_deref(),
        "boot" => cfg.secrets.boot_node_keys.as_deref(),
        _ => None,
    };
    if let Some(p) = sm.access(node_key_override) {
        prefer(&mut node_key, field(&p, "node-key"));
    }

    // ---- runtime environment file -----------------------------------------
    // On tmpfs, 0600, owned by the node user. Loaded by midnight-node.service
    // as an EnvironmentFile.
    let mut env = String::new();
    if !node_key.is_empty() {
        env.push_str(&format!("NODE_KEY={node_key}\n"));
    }

    if let Some(db) = &cfg.db {
        match sm.access(cfg.secrets.db.as_deref()) {
            Some(payload) => {
                let user = non_empty(field(&payload, "username"), &db.user);
                let name = non_empty(field(&payload, "database"), &db.name);
                let password = field(&payload, "password");

                if password.is_empty() {
                    warn("db secret has no password field");
                } else {
                    // Percent-encode: a password containing @ / : / ? would
                    // otherwise corrupt the connection URI.
                    env.push_str(&format!("POSTGRES_PASSWORD={password}\n"));
                    env.push_str(&format!(
                        "DB_SYNC_POSTGRES_CONNECTION_STRING=psql://{}:{}@{}:{}/{}?sslmode={}\n",
                        percent_encode(&user),
                        percent_encode(&password),
                        db.host,
                        db.port,
                        name,
                        db.ssl_mode,
                    ));

                    let line = pgpass_line(db, &name, &user, &password);
                    write_secret_file(&db.pgpass_file, line.as_bytes(), owner)?;
                }
            }
            None => warn("db secret unavailable"),
        }
    }

    write_secret_file(&cfg.env_file, env.as_bytes(), owner)?;

    // ---- validator seed files ---------------------------------------------
    // One phrase per file, no trailing newline — the node compares the file
    // contents verbatim.
    if let Some(dir) = &cfg.secrets_dir {
        mkdir_p(dir)?;
        for (value, name) in [
            (&aura, "aura-seed-phrase"),
            (&grandpa, "grandpa-seed-phrase"),
            (&cross_chain, "cross-chain-seed-phrase"),
        ] {
            if !value.is_empty() {
                write_secret_file(&dir.join(name), value.as_bytes(), owner)?;
            }
        }
        set_mode(dir, 0o700)?;
        owner.apply(dir)?;
    }

    // ---- libp2p network key -----------------------------------------------
    // The node expects raw ed25519 bytes, not the hex text.
    if !node_key.is_empty() {
        let raw = decode_hex(&node_key)
            .ok_or_else(|| "node key is not valid hex; leaving secret_ed25519 alone".to_string())?;
        mkdir_p(&cfg.network_dir)?;
        write_secret_file(&cfg.network_dir.join("secret_ed25519"), &raw, owner)?;
        chown_recursive(&cfg.chains_dir, owner)?;
    }

    Ok(())
}

/// Everything the process talks to Secret Manager with, plus the access token,
/// fetched once on first use rather than per secret.
struct SecretManager<'a> {
    project: &'a str,
    agent: ureq::Agent,
    token: Option<Option<String>>,
}

impl<'a> SecretManager<'a> {
    fn new(project: &'a str) -> Self {
        Self {
            project,
            agent: ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build(),
            token: None,
        }
    }

    fn token(&mut self) -> Option<&str> {
        if self.token.is_none() {
            let fetched = self
                .agent
                .get(METADATA_TOKEN_URL)
                .set("Metadata-Flavor", "Google")
                .call()
                .ok()
                .and_then(|r| r.into_string().ok())
                .and_then(|body| serde_json::from_str::<Value>(&body).ok())
                .and_then(|v| v.get("access_token")?.as_str().map(str::to_owned))
                .filter(|t| !t.is_empty());

            if fetched.is_none() {
                warn("no access token from the metadata server");
            }
            self.token = Some(fetched);
        }
        self.token.as_ref().and_then(|t| t.as_deref())
    }

    /// The decoded payload of `<id>`'s latest version, or None if the secret is
    /// absent, denied, or not the JSON object it is expected to be.
    fn access(&mut self, id: Option<&str>) -> Option<Value> {
        let id = id.filter(|s| !s.is_empty())?;
        let token = self.token()?.to_owned();

        let url = format!(
            "{SECRET_MANAGER}/projects/{}/secrets/{id}/versions/latest:access",
            self.project
        );
        let body = match self
            .agent
            .get(&url)
            .set("Authorization", &format!("Bearer {token}"))
            .call()
        {
            Ok(r) => r.into_string().ok()?,
            Err(_) => {
                warn(&format!("secret {id} unavailable"));
                return None;
            }
        };

        let encoded = serde_json::from_str::<Value>(&body)
            .ok()?
            .get("payload")?
            .get("data")?
            .as_str()?
            .to_owned();

        use base64::Engine as _;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(encoded.trim())
            .ok()?;
        serde_json::from_slice(&raw).ok()
    }
}

/// Unwraps either `"value"` or `{"secretSeed": "value"}`; anything else is
/// rendered the way `jq -r ... | tostring` rendered it.
fn field(payload: &Value, key: &str) -> String {
    match payload.get(key) {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(o)) => match o.get("secretSeed") {
            Some(Value::String(s)) => s.clone(),
            Some(v) => v.to_string(),
            None => String::new(),
        },
        Some(v) => v.to_string(),
    }
}

/// Higher-precedence source wins, but only when it actually carries a value.
fn prefer(current: &mut String, candidate: String) {
    if !candidate.is_empty() {
        *current = candidate;
    }
}

fn non_empty(value: String, fallback: &str) -> String {
    if value.is_empty() {
        fallback.to_owned()
    } else {
        value
    }
}

/// db-sync takes its whole connection from this file. Backslashes and colons
/// are the two characters pgpass treats specially.
fn pgpass_line(db: &DbConfig, name: &str, user: &str, password: &str) -> String {
    let mut escaped = String::with_capacity(password.len());
    for c in password.chars() {
        if c == '\\' || c == ':' {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    format!("{}:{}:{name}:{user}:{escaped}\n", db.host, db.port)
}

/// RFC 3986 unreserved set. Stricter than `jq`'s `@uri`, which also leaves
/// `!~*'()` alone — both decode back to the same credentials.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Hex, whitespace-tolerant and case-insensitive, as the shell version was.
fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let digits: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if digits.is_empty() || !digits.len().is_multiple_of(2) {
        return None;
    }
    digits
        .chunks(2)
        .map(|pair| {
            let hi = (pair[0] as char).to_digit(16)?;
            let lo = (pair[1] as char).to_digit(16)?;
            Some((hi * 16 + lo) as u8)
        })
        .collect()
}

/// uid/gid of the node user, resolved once.
#[derive(Clone, Copy)]
struct Owner {
    uid: libc::uid_t,
    gid: libc::gid_t,
}

impl Owner {
    fn resolve(user: &str, group: &str) -> Result<Self, String> {
        let name = CString::new(user).map_err(|_| "user name contains a NUL".to_string())?;
        let grp = CString::new(group).map_err(|_| "group name contains a NUL".to_string())?;

        // getpwnam/getgrnam return a pointer into static storage; it is read
        // out immediately and never held.
        let uid = unsafe {
            let pw = libc::getpwnam(name.as_ptr());
            if pw.is_null() {
                return Err(format!("no such user: {user}"));
            }
            (*pw).pw_uid
        };
        let gid = unsafe {
            let gr = libc::getgrnam(grp.as_ptr());
            if gr.is_null() {
                return Err(format!("no such group: {group}"));
            }
            (*gr).gr_gid
        };

        Ok(Self { uid, gid })
    }

    fn apply(self, path: &Path) -> Result<(), String> {
        self.chown(path, false)
    }

    /// For entries reached by walking a tree: a symlink is chowned as itself,
    /// so a link planted in the data directory cannot redirect the chown at
    /// something outside it.
    fn apply_nofollow(self, path: &Path) -> Result<(), String> {
        self.chown(path, true)
    }

    fn chown(self, path: &Path, nofollow: bool) -> Result<(), String> {
        let c = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| format!("path contains a NUL: {}", path.display()))?;
        let rc = unsafe {
            if nofollow {
                libc::lchown(c.as_ptr(), self.uid, self.gid)
            } else {
                libc::chown(c.as_ptr(), self.uid, self.gid)
            }
        };
        if rc != 0 {
            return Err(format!(
                "chown {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }
}

fn mkdir_p(dir: &Path) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))
}

fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(mode))
        .map_err(|e| format!("chmod {}: {e}", path.display()))
}

/// Create-or-truncate at 0600 and hand to the node user. The mode is set by
/// `open` rather than afterwards, so the content is never briefly readable.
fn write_secret_file(path: &Path, contents: &[u8], owner: Owner) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        mkdir_p(parent)?;
    }

    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    f.write_all(contents)
        .map_err(|e| format!("write {}: {e}", path.display()))?;

    // An existing file keeps its old mode through `open`.
    set_mode(path, 0o600)?;
    owner.apply(path)
}

fn chown_recursive(dir: &Path, owner: Owner) -> Result<(), String> {
    if !dir.exists() {
        return Ok(());
    }
    owner.apply(dir)?;

    let entries = fs::read_dir(dir).map_err(|e| format!("read {}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("read {}: {e}", dir.display()))?;
        let path = entry.path();
        let meta =
            fs::symlink_metadata(&path).map_err(|e| format!("stat {}: {e}", path.display()))?;
        if meta.is_dir() {
            chown_recursive(&path, owner)?;
        } else {
            owner.apply_nofollow(&path)?;
        }
    }
    Ok(())
}

fn warn(message: &str) {
    eprintln!("gcp-secrets: {message}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn field_unwraps_both_payload_shapes() {
        let v = payload(
            r#"{"aura": "phrase one", "grandpa": {"secretSeed": "phrase two"}, "empty": null}"#,
        );
        assert_eq!(field(&v, "aura"), "phrase one");
        assert_eq!(field(&v, "grandpa"), "phrase two");
        assert_eq!(field(&v, "empty"), "");
        assert_eq!(field(&v, "absent"), "");
    }

    #[test]
    fn precedence_only_moves_on_a_real_value() {
        let mut seed = "from-node".to_string();
        prefer(&mut seed, String::new());
        assert_eq!(seed, "from-node");
        prefer(&mut seed, "from-seed-phrases".to_string());
        assert_eq!(seed, "from-seed-phrases");
    }

    #[test]
    fn uri_encoding_covers_the_characters_that_break_a_dsn() {
        assert_eq!(percent_encode("p@ss:w/rd?"), "p%40ss%3Aw%2Frd%3F");
        assert_eq!(percent_encode("plain-_.~"), "plain-_.~");
    }

    #[test]
    fn pgpass_escapes_backslash_and_colon() {
        let db = DbConfig {
            host: "10.0.0.5".into(),
            port: 5432,
            name: "cexplorer".into(),
            user: "dbsync".into(),
            ssl_mode: "require".into(),
            pgpass_file: PathBuf::from("/opt/cardano/dbsync/.pgpassfile"),
        };
        assert_eq!(
            pgpass_line(&db, "cexplorer", "dbsync", r"pa:ss\word"),
            "10.0.0.5:5432:cexplorer:dbsync:pa\\:ss\\\\word\n"
        );
    }

    #[test]
    fn hex_decoding_is_tolerant_of_whitespace_and_case() {
        assert_eq!(decode_hex(" 00ff AB\n").unwrap(), vec![0x00, 0xff, 0xab]);
        assert_eq!(decode_hex(""), None);
        assert_eq!(decode_hex("abc"), None);
        assert_eq!(decode_hex("zz"), None);
    }
}
