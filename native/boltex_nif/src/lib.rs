mod atoms;
mod error;
mod graph;
mod query;
mod runtime;
mod stream;
mod summary;
mod txn;
mod types;

use rustler::{Env, Term};

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.BoltexNif.Native", load = on_load);
