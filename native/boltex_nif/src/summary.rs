//! Encode `neo4rs::ResultSummary` (available behind `unstable-result-summary`,
//! which we always enable via `unstable-v1`) to Elixir structs.

use neo4rs::summary::{Counters, Notification, ResultSummary};
use rustler::{types::atom as ratom, Atom, Encoder, Env, Term};

use crate::atoms;

pub fn encode_summary<'a>(env: Env<'a>, s: ResultSummary) -> Term<'a> {
    let bookmark = match &s.bookmark {
        Some(b) => b.as_str().encode(env),
        None => ratom::nil().encode(env),
    };
    let available = match s.available_after() {
        Some(d) => (d.as_millis() as i64).encode(env),
        None => ratom::nil().encode(env),
    };
    let consumed = match s.consumed_after() {
        Some(d) => (d.as_millis() as i64).encode(env),
        None => ratom::nil().encode(env),
    };
    let query_type_t = format!("{:?}", s.query_type()).to_lowercase().encode(env);
    let db_t = match s.db() {
        Some(d) => d.encode(env),
        None => ratom::nil().encode(env),
    };
    let stats_t = encode_counters(env, s.stats());
    let notifs_t: Vec<Term<'a>> = s
        .notifications()
        .iter()
        .map(|n| encode_notification(env, n))
        .collect();
    let notifs_term = notifs_t.encode(env);

    make_struct(
        env,
        atoms::summary_module(),
        &[
            (atoms::bookmark(), bookmark),
            (atoms::available_after_ms(), available),
            (atoms::consumed_after_ms(), consumed),
            (atoms::query_type(), query_type_t),
            (atoms::db(), db_t),
            (atoms::stats(), stats_t),
            (atoms::notifications(), notifs_term),
        ],
    )
}

fn encode_counters<'a>(env: Env<'a>, c: &Counters) -> Term<'a> {
    make_struct(
        env,
        atoms::counters_module(),
        &[
            (atoms::nodes_created(), (c.nodes_created as i64).encode(env)),
            (atoms::nodes_deleted(), (c.nodes_deleted as i64).encode(env)),
            (
                atoms::relationships_created(),
                (c.relationships_created as i64).encode(env),
            ),
            (
                atoms::relationships_deleted(),
                (c.relationships_deleted as i64).encode(env),
            ),
            (atoms::properties_set(), (c.properties_set as i64).encode(env)),
            (atoms::labels_added(), (c.labels_added as i64).encode(env)),
            (atoms::labels_removed(), (c.labels_removed as i64).encode(env)),
            (atoms::indexes_added(), (c.indexes_added as i64).encode(env)),
            (atoms::indexes_removed(), (c.indexes_removed as i64).encode(env)),
            (
                atoms::constraints_added(),
                (c.constraints_added as i64).encode(env),
            ),
            (
                atoms::constraints_removed(),
                (c.constraints_removed as i64).encode(env),
            ),
            (atoms::system_updates(), (c.system_updates as i64).encode(env)),
        ],
    )
}

fn encode_notification<'a>(env: Env<'a>, n: &Notification) -> Term<'a> {
    let code = opt_str(env, n.code.as_deref());
    let title = opt_str(env, n.title.as_deref());
    let desc = opt_str(env, n.description.as_deref());
    let sev = match &n.severity {
        Some(s) => format!("{:?}", s).to_lowercase().encode(env),
        None => ratom::nil().encode(env),
    };
    let cat = match &n.category {
        Some(c) => format!("{:?}", c).to_lowercase().encode(env),
        None => ratom::nil().encode(env),
    };
    let pos = match &n.position {
        Some(p) => make_struct(
            env,
            atoms::input_position_module(),
            &[
                (atoms::offset(), (p.offset as i64).encode(env)),
                (atoms::line(), (p.line as i64).encode(env)),
                (atoms::column(), (p.column as i64).encode(env)),
            ],
        ),
        None => ratom::nil().encode(env),
    };
    make_struct(
        env,
        atoms::notification_module(),
        &[
            (atoms::code(), code),
            (atoms::title(), title),
            (atoms::description(), desc),
            (atoms::severity(), sev),
            (atoms::category(), cat),
            (atoms::position(), pos),
        ],
    )
}

fn opt_str<'a>(env: Env<'a>, s: Option<&str>) -> Term<'a> {
    match s {
        Some(s) => s.encode(env),
        None => ratom::nil().encode(env),
    }
}

fn make_struct<'a>(env: Env<'a>, module: Atom, fields: &[(Atom, Term<'a>)]) -> Term<'a> {
    let mut map = Term::map_new(env);
    map = map
        .map_put(atoms::struct_key().encode(env), module.encode(env))
        .expect("map_put struct");
    for (k, v) in fields {
        map = map.map_put(k.encode(env), *v).expect("map_put field");
    }
    map
}
