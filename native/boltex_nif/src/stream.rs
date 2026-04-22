//! Auto-commit RowStream support. A `StreamResource` owns the
//! `DetachedRowStream` returned by `Graph::execute`; each `stream_next` NIF
//! pulls a single row (or `:done`) asynchronously.

use neo4rs::{BoltType, DetachedRowStream};
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use tokio::sync::Mutex;

use crate::atoms;
use crate::error::NifError;
use crate::graph::GraphResource;
use crate::runtime::{self, Response};
use crate::types;

pub struct StreamResource(pub Mutex<Option<DetachedRowStream>>);

#[rustler::resource_impl]
impl Resource for StreamResource {}

#[rustler::nif]
fn stream_start<'a>(
    env: Env<'a>,
    graph: ResourceArc<GraphResource>,
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
    let g = graph.0.clone();
    runtime::spawn(env, async move {
        let mut q = neo4rs::query(&cypher);
        for (k, v) in decoded {
            q = q.param(&k, v);
        }
        match g.execute(q).await {
            Ok(stream) => {
                let res = ResourceArc::new(StreamResource(Mutex::new(Some(stream))));
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
fn stream_next<'a>(env: Env<'a>, stream: ResourceArc<StreamResource>) -> Term<'a> {
    let handle = stream.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        let Some(s) = guard.as_mut() else {
            return Response::new(move |env| (atoms::error(), atoms::closed().encode(env)).encode(env));
        };
        match s.next().await {
            Ok(Some(row)) => {
                let keys: Vec<String> = row.keys().into_iter().map(|k| k.value.clone()).collect();
                let mut pairs = Vec::with_capacity(keys.len());
                for key in keys {
                    match row.get::<BoltType>(&key) {
                        Ok(v) => pairs.push((key, v)),
                        Err(e) => {
                            let err = NifError::from(neo4rs::Error::DeserializationError(e));
                            return Response::new(move |env| {
                                (atoms::error(), err.encode_term(env)).encode(env)
                            });
                        }
                    }
                }
                Response::new(move |env| {
                    let mut map = Term::map_new(env);
                    for (k, v) in pairs {
                        let key = k.encode(env);
                        let val = types::encode_bolt(env, v);
                        map = map.map_put(key, val).expect("map_put row");
                    }
                    (atoms::ok(), map).encode(env)
                })
            }
            Ok(None) => {
                // Drop the stream now that it's exhausted.
                *guard = None;
                Response::new(move |env| atoms::done().encode(env))
            }
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

#[rustler::nif]
fn stream_close<'a>(env: Env<'a>, stream: ResourceArc<StreamResource>) -> Term<'a> {
    let handle = stream.clone();
    runtime::spawn(env, async move {
        let mut guard = handle.0.lock().await;
        *guard = None;
        Response::new(move |env| atoms::ok().encode(env))
    })
}
