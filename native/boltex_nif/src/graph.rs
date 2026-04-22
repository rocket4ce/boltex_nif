use neo4rs::{ConfigBuilder, Graph};
use rustler::{Encoder, Env, NifMap, Resource, ResourceArc, Term};

use crate::atoms;
use crate::error::NifError;
use crate::runtime::{self, Response};

/// Opaque handle exposed to Elixir as an NIF resource.
#[allow(dead_code)]
pub struct GraphResource(pub Graph);

#[rustler::resource_impl]
impl Resource for GraphResource {}

#[derive(NifMap)]
pub struct ConnectConfig {
    pub uri: String,
    pub user: String,
    pub password: String,
    pub db: String,
    pub fetch_size: i64,
    pub max_connections: i64,
    pub impersonate_user: String,
    pub tls_mode: String, // "none" | "ca" | "mutual" | "skip"
    pub tls_ca: String,
    pub tls_cert: String,
    pub tls_key: String,
}

#[rustler::nif]
fn connect<'a>(env: Env<'a>, config: ConnectConfig) -> Term<'a> {
    runtime::spawn(env, async move {
        match build_and_connect(config) {
            Ok(graph) => {
                let resource = ResourceArc::new(GraphResource(graph));
                Response::new(move |env| (atoms::ok(), resource).encode(env))
            }
            Err(err) => {
                let err = NifError::from(err);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

fn build_and_connect(cfg: ConnectConfig) -> Result<Graph, neo4rs::Error> {
    let mut builder = ConfigBuilder::default()
        .uri(cfg.uri.as_str())
        .user(cfg.user.as_str())
        .password(cfg.password.as_str());

    if !cfg.db.is_empty() {
        builder = builder.db(cfg.db.as_str());
    }
    if cfg.fetch_size > 0 {
        builder = builder.fetch_size(cfg.fetch_size as usize);
    }
    if cfg.max_connections > 0 {
        builder = builder.max_connections(cfg.max_connections as usize);
    }
    if !cfg.impersonate_user.is_empty() {
        builder = builder.with_impersonate_user(cfg.impersonate_user.as_str());
    }

    builder = apply_tls(builder, &cfg);

    let config = builder.build()?;
    Graph::connect(config)
}

fn apply_tls(mut builder: ConfigBuilder, cfg: &ConnectConfig) -> ConfigBuilder {
    match cfg.tls_mode.as_str() {
        "ca" if !cfg.tls_ca.is_empty() => {
            builder = builder.with_client_certificate(cfg.tls_ca.as_str());
        }
        "mutual" if !cfg.tls_cert.is_empty() && !cfg.tls_key.is_empty() => {
            let ca_opt = if cfg.tls_ca.is_empty() {
                None
            } else {
                Some(std::path::Path::new(&cfg.tls_ca))
            };
            builder = builder.with_mutual_tls_validation(
                ca_opt,
                cfg.tls_cert.as_str(),
                cfg.tls_key.as_str(),
            );
        }
        "skip" => {
            builder = builder.skip_ssl_validation();
        }
        _ => {}
    }
    builder
}
