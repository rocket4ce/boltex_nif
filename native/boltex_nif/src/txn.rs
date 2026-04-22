//! Transaction support: `Txn` is wrapped in a Tokio `Mutex<Option<Txn>>` so
//! `run`/`execute` can take `&mut self` and `commit`/`rollback` can consume.
//! After commit/rollback the `Option` is `None` and further calls fail with
//! `:closed`.

use neo4rs::{BoltType, Query, Txn};
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use tokio::sync::Mutex;

use crate::atoms;
use crate::error::NifError;
use crate::graph::GraphResource;
use crate::runtime::{self, Response};
use crate::summary::encode_summary;
use crate::types;

pub struct TxnResource(pub Mutex<Option<Txn>>);

#[rustler::resource_impl]
impl Resource for TxnResource {}

impl TxnResource {
    pub fn new(txn: Txn) -> ResourceArc<Self> {
        ResourceArc::new(TxnResource(Mutex::new(Some(txn))))
    }
}

fn closed_error<'a>(env: Env<'a>) -> Term<'a> {
    let err = NifError::argument("transaction already committed or rolled back");
    runtime::spawn(env, async move {
        Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
    })
}

fn build_query(cypher: &str, params: Vec<(String, BoltType)>) -> Query {
    let mut q = neo4rs::query(cypher);
    for (k, v) in params {
        q = q.param(&k, v);
    }
    q
}

#[rustler::nif]
fn begin_transaction<'a>(env: Env<'a>, graph: ResourceArc<GraphResource>) -> Term<'a> {
    let g = graph.0.clone();
    runtime::spawn(env, async move {
        match g.start_txn().await {
            Ok(txn) => {
                let res = TxnResource::new(txn);
                Response::new(move |env| (atoms::ok(), res).encode(env))
            }
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

#[rustler::nif]
fn txn_run<'a>(
    env: Env<'a>,
    txn: ResourceArc<TxnResource>,
    cypher: String,
    params: Term<'a>,
) -> Term<'a> {
    let decoded = match types::decode_params(params) {
        Ok(p) => p,
        Err(e) => {
            return runtime::spawn(env, async move {
                Response::new(move |env| (atoms::error(), e.encode_term(env)).encode(env))
            })
        }
    };
    let handle = txn.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        let Some(t) = guard.as_mut() else {
            let err = NifError::argument("transaction already closed");
            return Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env));
        };
        let q = build_query(&cypher, decoded);
        match t.run(q).await {
            Ok(summary) => Response::new(move |env| {
                let s = encode_summary(env, summary);
                (atoms::ok(), s).encode(env)
            }),
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

#[rustler::nif]
fn txn_execute<'a>(
    env: Env<'a>,
    txn: ResourceArc<TxnResource>,
    cypher: String,
    params: Term<'a>,
) -> Term<'a> {
    let decoded = match types::decode_params(params) {
        Ok(p) => p,
        Err(e) => {
            return runtime::spawn(env, async move {
                Response::new(move |env| (atoms::error(), e.encode_term(env)).encode(env))
            })
        }
    };
    let handle = txn.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        let Some(t) = guard.as_mut() else {
            let err = NifError::argument("transaction already closed");
            return Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env));
        };
        let q = build_query(&cypher, decoded);
        match collect_txn_rows(t, q).await {
            Ok(rows) => Response::new(move |env| {
                let list = crate::query::encode_rows(env, rows);
                (atoms::ok(), list).encode(env)
            }),
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

async fn collect_txn_rows(
    txn: &mut Txn,
    q: Query,
) -> Result<Vec<Vec<(String, BoltType)>>, neo4rs::Error> {
    let mut stream = txn.execute(q).await?;
    let mut out = Vec::new();
    loop {
        match stream.next(&mut *txn).await? {
            Some(row) => {
                let keys: Vec<String> = row.keys().into_iter().map(|k| k.value.clone()).collect();
                let mut pairs = Vec::with_capacity(keys.len());
                for key in keys {
                    let v = row
                        .get::<BoltType>(&key)
                        .map_err(neo4rs::Error::DeserializationError)?;
                    pairs.push((key, v));
                }
                out.push(pairs);
            }
            None => break,
        }
    }
    Ok(out)
}

#[rustler::nif]
fn commit<'a>(env: Env<'a>, txn: ResourceArc<TxnResource>) -> Term<'a> {
    let handle = txn.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        let Some(t) = guard.take() else {
            return Response::new(move |env| (atoms::error(), atoms::closed().encode(env)).encode(env));
        };
        match t.commit().await {
            Ok(bookmark) => {
                let bookmark_term = match bookmark {
                    Some(b) => move_bookmark(b),
                    None => None,
                };
                Response::new(move |env| match bookmark_term {
                    Some(b) => (atoms::ok(), b.encode(env)).encode(env),
                    None => atoms::ok().encode(env),
                })
            }
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

// Helper to pass an `Option<String>` to the closure without capturing `env`.
fn move_bookmark(b: String) -> Option<String> {
    Some(b)
}

#[rustler::nif]
fn rollback<'a>(env: Env<'a>, txn: ResourceArc<TxnResource>) -> Term<'a> {
    let handle = txn.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        let Some(t) = guard.take() else {
            return Response::new(move |env| (atoms::error(), atoms::closed().encode(env)).encode(env));
        };
        match t.rollback().await {
            Ok(()) => Response::new(move |env| atoms::ok().encode(env)),
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

// Silence unused warnings if nothing else references this helper.
#[allow(dead_code)]
fn _closed_error_probe(env: Env<'_>) -> Term<'_> {
    closed_error(env)
}
