use neo4rs::{query, BoltType, Query};
use rustler::{Encoder, Env, ResourceArc, Term};

use crate::atoms;
use crate::error::NifError;
use crate::graph::GraphResource;
use crate::runtime::{self, Response};
use crate::summary::encode_summary;
use crate::types;

fn build_query(cypher: &str, params: Vec<(String, BoltType)>) -> Query {
    let mut q = query(cypher);
    for (k, v) in params {
        q = q.param(&k, v);
    }
    q
}

fn error_response<'a>(env: Env<'a>, err: NifError) -> Term<'a> {
    runtime::spawn(env, async move {
        Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
    })
}

#[rustler::nif]
fn run<'a>(
    env: Env<'a>,
    graph: ResourceArc<GraphResource>,
    cypher: String,
    params: Term<'a>,
) -> Term<'a> {
    let params_decoded = match types::decode_params(params) {
        Ok(p) => p,
        Err(e) => return error_response(env, e),
    };
    let g = graph.0.clone();
    runtime::spawn(env, async move {
        let q = build_query(&cypher, params_decoded);
        match g.run(q).await {
            Ok(_summary) => Response::new(move |env| atoms::ok().encode(env)),
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

#[rustler::nif]
fn run_with_summary<'a>(
    env: Env<'a>,
    graph: ResourceArc<GraphResource>,
    cypher: String,
    params: Term<'a>,
) -> Term<'a> {
    let params_decoded = match types::decode_params(params) {
        Ok(p) => p,
        Err(e) => return error_response(env, e),
    };
    let g = graph.0.clone();
    runtime::spawn(env, async move {
        let q = build_query(&cypher, params_decoded);
        match g.run(q).await {
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
fn execute<'a>(
    env: Env<'a>,
    graph: ResourceArc<GraphResource>,
    cypher: String,
    params: Term<'a>,
) -> Term<'a> {
    let params_decoded = match types::decode_params(params) {
        Ok(p) => p,
        Err(e) => return error_response(env, e),
    };
    let g = graph.0.clone();
    runtime::spawn(env, async move {
        let q = build_query(&cypher, params_decoded);
        match collect_rows(&g, q).await {
            Ok(rows) => Response::new(move |env| {
                let list = encode_rows(env, rows);
                (atoms::ok(), list).encode(env)
            }),
            Err(e) => {
                let err = NifError::from(e);
                Response::new(move |env| (atoms::error(), err.encode_term(env)).encode(env))
            }
        }
    })
}

/// A single result row is materialized as an ordered list of `(column_name, BoltType)`
/// pairs so we preserve column order and avoid bouncing through an intermediate map.
pub type RowPairs = Vec<(String, BoltType)>;

async fn collect_rows(
    graph: &neo4rs::Graph,
    q: Query,
) -> Result<Vec<RowPairs>, neo4rs::Error> {
    let mut stream = graph.execute(q).await?;
    let mut out = Vec::new();
    while let Some(row) = stream.next().await? {
        let keys: Vec<String> = row.keys().into_iter().map(|k| k.value.clone()).collect();
        let mut pairs = Vec::with_capacity(keys.len());
        for key in keys {
            match row.get::<BoltType>(&key) {
                Ok(v) => pairs.push((key, v)),
                Err(e) => return Err(neo4rs::Error::DeserializationError(e)),
            }
        }
        out.push(pairs);
    }
    Ok(out)
}

pub fn encode_rows<'a>(env: Env<'a>, rows: Vec<RowPairs>) -> Term<'a> {
    let encoded: Vec<Term<'a>> = rows.into_iter().map(|row| encode_row(env, row)).collect();
    encoded.encode(env)
}

fn encode_row<'a>(env: Env<'a>, row: RowPairs) -> Term<'a> {
    let mut map = Term::map_new(env);
    for (k, v) in row {
        let key = k.encode(env);
        let val = types::encode_bolt(env, v);
        map = map.map_put(key, val).expect("map_put row");
    }
    map
}
