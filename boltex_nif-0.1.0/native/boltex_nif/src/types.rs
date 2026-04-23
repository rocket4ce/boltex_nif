//! Two-way marshalling between `neo4rs::BoltType` and Elixir terms.
//!
//! Encoding (`BoltType` → Term) is called from inside `OwnedEnv::send_and_clear`,
//! so the target `Env<'a>` is the reply env.
//!
//! Decoding (Term → `BoltType`) is called synchronously while the NIF still
//! holds the caller's `Env`, before anything async is spawned. Decoded values
//! must be owned (no lifetimes tied to the caller env) so they can be moved
//! into the spawned future.

use std::collections::HashMap;

use chrono::{
    DateTime, Datelike, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, Timelike,
};
use neo4rs::{
    BoltBoolean, BoltBytes, BoltDate, BoltDateTime, BoltDateTimeZoneId, BoltDuration, BoltFloat,
    BoltInteger, BoltList, BoltLocalDateTime, BoltLocalTime, BoltMap, BoltNode, BoltNull, BoltPath,
    BoltPoint2D, BoltPoint3D, BoltRelation, BoltString, BoltTime, BoltType, BoltUnboundedRelation,
};
use rustler::{
    types::{atom as ratom, tuple, Binary, MapIterator},
    Atom, Encoder, Env, Term, TermType,
};

use crate::atoms;
use crate::error::NifError;

// =======================================================================
// Encoding: BoltType -> Elixir Term
// =======================================================================

pub fn encode_bolt<'a>(env: Env<'a>, value: BoltType) -> Term<'a> {
    match value {
        BoltType::Null(_) => ratom::nil().encode(env),
        BoltType::Boolean(BoltBoolean { value }) => value.encode(env),
        BoltType::Integer(BoltInteger { value }) => value.encode(env),
        BoltType::Float(BoltFloat { value }) => value.encode(env),
        BoltType::String(BoltString { value }) => value.encode(env),
        BoltType::Bytes(b) => encode_bytes(env, b),
        BoltType::List(l) => encode_list(env, l),
        BoltType::Map(m) => encode_map(env, m),
        BoltType::Node(n) => encode_node(env, n),
        BoltType::Relation(r) => encode_relation(env, r),
        BoltType::UnboundedRelation(r) => encode_ubrel(env, r),
        BoltType::Path(p) => encode_path(env, p),
        BoltType::Point2D(p) => encode_point2d(env, p),
        BoltType::Point3D(p) => encode_point3d(env, p),
        BoltType::Duration(d) => encode_duration(env, d),
        BoltType::Date(d) => encode_date(env, d),
        BoltType::LocalTime(t) => encode_local_time(env, t),
        BoltType::LocalDateTime(dt) => encode_local_datetime(env, dt),
        BoltType::Time(t) => encode_time(env, t),
        BoltType::DateTime(dt) => encode_datetime(env, dt),
        BoltType::DateTimeZoneId(dt) => encode_datetime_zone_id(env, dt),
    }
}

fn encode_bytes<'a>(env: Env<'a>, b: BoltBytes) -> Term<'a> {
    let slice: Vec<u8> = b.value.to_vec();
    let mut bin = rustler::OwnedBinary::new(slice.len()).expect("alloc binary");
    bin.as_mut_slice().copy_from_slice(&slice);
    let bin_term = Binary::from_owned(bin, env).to_term(env);
    (atoms::bytes(), bin_term).encode(env)
}

fn encode_list<'a>(env: Env<'a>, l: BoltList) -> Term<'a> {
    let items: Vec<Term<'a>> = l.value.into_iter().map(|v| encode_bolt(env, v)).collect();
    items.encode(env)
}

fn encode_map<'a>(env: Env<'a>, m: BoltMap) -> Term<'a> {
    let mut map = Term::map_new(env);
    for (k, v) in m.value.into_iter() {
        let key: Term = k.value.encode(env);
        let val = encode_bolt(env, v);
        map = map.map_put(key, val).expect("map_put");
    }
    map
}

/// Build a map with `__struct__` plus the listed fields.
fn encode_struct<'a>(env: Env<'a>, module: Atom, fields: &[(Atom, Term<'a>)]) -> Term<'a> {
    let mut map = Term::map_new(env);
    map = map
        .map_put(atoms::struct_key().encode(env), module.encode(env))
        .expect("map_put struct");
    for (k, v) in fields {
        map = map.map_put(k.encode(env), *v).expect("map_put field");
    }
    map
}

fn encode_node<'a>(env: Env<'a>, n: BoltNode) -> Term<'a> {
    let labels: Vec<String> = n
        .labels
        .value
        .into_iter()
        .filter_map(|b| match b {
            BoltType::String(s) => Some(s.value),
            _ => None,
        })
        .collect();
    let props = encode_map(env, n.properties);
    let id_t = n.id.value.encode(env);
    let labels_t = labels.encode(env);
    encode_struct(
        env,
        atoms::node_module(),
        &[
            (atoms::id(), id_t),
            (atoms::labels(), labels_t),
            (atoms::properties(), props),
        ],
    )
}

fn encode_relation<'a>(env: Env<'a>, r: BoltRelation) -> Term<'a> {
    let props = encode_map(env, r.properties);
    let id_t = r.id.value.encode(env);
    let start_t = r.start_node_id.value.encode(env);
    let end_t = r.end_node_id.value.encode(env);
    let type_t = r.typ.value.encode(env);
    encode_struct(
        env,
        atoms::relationship_module(),
        &[
            (atoms::id(), id_t),
            (atoms::start_node_id(), start_t),
            (atoms::end_node_id(), end_t),
            (atoms::type_key(), type_t),
            (atoms::properties(), props),
        ],
    )
}

fn encode_ubrel<'a>(env: Env<'a>, r: BoltUnboundedRelation) -> Term<'a> {
    let props = encode_map(env, r.properties);
    let id_t = r.id.value.encode(env);
    let type_t = r.typ.value.encode(env);
    encode_struct(
        env,
        atoms::unbound_relationship_module(),
        &[
            (atoms::id(), id_t),
            (atoms::type_key(), type_t),
            (atoms::properties(), props),
        ],
    )
}

fn encode_path<'a>(env: Env<'a>, p: BoltPath) -> Term<'a> {
    let nodes: Vec<Term<'a>> = p
        .nodes
        .value
        .into_iter()
        .filter_map(|b| match b {
            BoltType::Node(n) => Some(encode_node(env, n)),
            _ => None,
        })
        .collect();
    let rels: Vec<Term<'a>> = p
        .rels
        .value
        .into_iter()
        .filter_map(|b| match b {
            BoltType::UnboundedRelation(r) => Some(encode_ubrel(env, r)),
            BoltType::Relation(r) => Some(encode_relation(env, r)),
            _ => None,
        })
        .collect();
    let indices: Vec<i64> = p
        .indices
        .value
        .into_iter()
        .filter_map(|b| match b {
            BoltType::Integer(i) => Some(i.value),
            _ => None,
        })
        .collect();
    let nodes_t = nodes.encode(env);
    let rels_t = rels.encode(env);
    let indices_t = indices.encode(env);
    encode_struct(
        env,
        atoms::path_module(),
        &[
            (atoms::nodes(), nodes_t),
            (atoms::relationships(), rels_t),
            (atoms::indices(), indices_t),
        ],
    )
}

fn encode_point2d<'a>(env: Env<'a>, p: BoltPoint2D) -> Term<'a> {
    let srid = p.sr_id.value.encode(env);
    let x = p.x.value.encode(env);
    let y = p.y.value.encode(env);
    let z = ratom::nil().encode(env);
    encode_struct(
        env,
        atoms::point_module(),
        &[
            (atoms::srid(), srid),
            (atoms::x(), x),
            (atoms::y(), y),
            (atoms::z(), z),
        ],
    )
}

fn encode_point3d<'a>(env: Env<'a>, p: BoltPoint3D) -> Term<'a> {
    let srid = p.sr_id.value.encode(env);
    let x = p.x.value.encode(env);
    let y = p.y.value.encode(env);
    let z = p.z.value.encode(env);
    encode_struct(
        env,
        atoms::point_module(),
        &[
            (atoms::srid(), srid),
            (atoms::x(), x),
            (atoms::y(), y),
            (atoms::z(), z),
        ],
    )
}

// BoltDuration fields are pub(crate); extract the four i64 components via Debug output.
fn duration_components(d: &BoltDuration) -> (i64, i64, i64, i64) {
    let s = format!("{:?}", d);
    let mut vals = s.split("value:").skip(1).filter_map(|chunk| {
        chunk
            .trim_start()
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect::<String>()
            .parse::<i64>()
            .ok()
    });
    (
        vals.next().unwrap_or(0),
        vals.next().unwrap_or(0),
        vals.next().unwrap_or(0),
        vals.next().unwrap_or(0),
    )
}

fn encode_duration<'a>(env: Env<'a>, d: BoltDuration) -> Term<'a> {
    let (months, days, seconds, nanos) = duration_components(&d);
    let m = months.encode(env);
    let d_t = days.encode(env);
    let s = seconds.encode(env);
    let n = nanos.encode(env);
    encode_struct(
        env,
        atoms::duration_module(),
        &[
            (atoms::months(), m),
            (atoms::days(), d_t),
            (atoms::seconds(), s),
            (atoms::nanoseconds(), n),
        ],
    )
}

fn encode_microsecond_tuple<'a>(env: Env<'a>, nanos: u32) -> Term<'a> {
    let usec = (nanos / 1_000) as i64;
    tuple::make_tuple(env, &[usec.encode(env), 6i64.encode(env)])
}

fn encode_elx_date<'a>(env: Env<'a>, d: NaiveDate) -> Term<'a> {
    let cal = atoms::calendar_iso().encode(env);
    let y = (d.year() as i64).encode(env);
    let m = (d.month() as i64).encode(env);
    let dd = (d.day() as i64).encode(env);
    encode_struct(
        env,
        atoms::date_module(),
        &[
            (atoms::calendar(), cal),
            (atoms::year(), y),
            (atoms::month(), m),
            (atoms::day(), dd),
        ],
    )
}

fn encode_elx_time<'a>(env: Env<'a>, t: NaiveTime) -> Term<'a> {
    let cal = atoms::calendar_iso().encode(env);
    let h = (t.hour() as i64).encode(env);
    let mi = (t.minute() as i64).encode(env);
    let s = (t.second() as i64).encode(env);
    let us = encode_microsecond_tuple(env, t.nanosecond());
    encode_struct(
        env,
        atoms::time_module(),
        &[
            (atoms::calendar(), cal),
            (atoms::hour(), h),
            (atoms::minute(), mi),
            (atoms::second(), s),
            (atoms::microsecond(), us),
        ],
    )
}

fn encode_elx_naive_datetime<'a>(env: Env<'a>, dt: NaiveDateTime) -> Term<'a> {
    let cal = atoms::calendar_iso().encode(env);
    let y = (dt.year() as i64).encode(env);
    let m = (dt.month() as i64).encode(env);
    let dd = (dt.day() as i64).encode(env);
    let h = (dt.hour() as i64).encode(env);
    let mi = (dt.minute() as i64).encode(env);
    let s = (dt.second() as i64).encode(env);
    let us = encode_microsecond_tuple(env, dt.nanosecond());
    encode_struct(
        env,
        atoms::naive_datetime_module(),
        &[
            (atoms::calendar(), cal),
            (atoms::year(), y),
            (atoms::month(), m),
            (atoms::day(), dd),
            (atoms::hour(), h),
            (atoms::minute(), mi),
            (atoms::second(), s),
            (atoms::microsecond(), us),
        ],
    )
}

fn encode_date<'a>(env: Env<'a>, d: BoltDate) -> Term<'a> {
    match NaiveDate::try_from(&d) {
        Ok(nd) => encode_elx_date(env, nd),
        Err(_) => ratom::nil().encode(env),
    }
}

fn encode_local_time<'a>(env: Env<'a>, t: BoltLocalTime) -> Term<'a> {
    let nt: NaiveTime = (&t).into();
    encode_elx_time(env, nt)
}

fn encode_local_datetime<'a>(env: Env<'a>, dt: BoltLocalDateTime) -> Term<'a> {
    match NaiveDateTime::try_from(&dt) {
        Ok(nd) => encode_elx_naive_datetime(env, nd),
        Err(_) => ratom::nil().encode(env),
    }
}

fn encode_time<'a>(env: Env<'a>, t: BoltTime) -> Term<'a> {
    let (nt, off): (NaiveTime, FixedOffset) = (&t).into();
    let time_t = encode_elx_time(env, nt);
    let off_t = (off.local_minus_utc() as i64).encode(env);
    encode_struct(
        env,
        atoms::bolt_time_module(),
        &[
            (atoms::time(), time_t),
            (atoms::offset_seconds(), off_t),
        ],
    )
}

fn encode_datetime<'a>(env: Env<'a>, dt: BoltDateTime) -> Term<'a> {
    match DateTime::<FixedOffset>::try_from(&dt) {
        Ok(d) => {
            let naive_t = encode_elx_naive_datetime(env, d.naive_local());
            let off_t = (d.offset().local_minus_utc() as i64).encode(env);
            encode_struct(
                env,
                atoms::bolt_datetime_module(),
                &[
                    (atoms::naive(), naive_t),
                    (atoms::offset_seconds(), off_t),
                ],
            )
        }
        Err(_) => ratom::nil().encode(env),
    }
}

fn encode_datetime_zone_id<'a>(env: Env<'a>, dt: BoltDateTimeZoneId) -> Term<'a> {
    let tz_id = dt.tz_id().to_string();
    match NaiveDateTime::try_from(&dt) {
        Ok(nd) => {
            let naive_t = encode_elx_naive_datetime(env, nd);
            let tz_t = tz_id.encode(env);
            encode_struct(
                env,
                atoms::datetime_zone_id_module(),
                &[
                    (atoms::naive(), naive_t),
                    (atoms::tz_id(), tz_t),
                ],
            )
        }
        Err(_) => ratom::nil().encode(env),
    }
}

// =======================================================================
// Decoding: Elixir Term -> BoltType
// =======================================================================

pub fn decode_bolt(term: Term) -> Result<BoltType, NifError> {
    match term.get_type() {
        TermType::Atom => decode_atom(term),
        TermType::Integer => {
            let n: i64 = term
                .decode()
                .map_err(|_| NifError::argument("invalid integer"))?;
            Ok(BoltType::Integer(n.into()))
        }
        TermType::Float => {
            let f: f64 = term
                .decode()
                .map_err(|_| NifError::argument("invalid float"))?;
            Ok(BoltType::Float(BoltFloat { value: f }))
        }
        TermType::Binary => {
            let bin: Binary = term
                .decode()
                .map_err(|_| NifError::argument("invalid binary"))?;
            match std::str::from_utf8(bin.as_slice()) {
                Ok(s) => Ok(BoltType::String(BoltString {
                    value: s.to_string(),
                })),
                Err(_) => Ok(BoltType::Bytes(BoltBytes {
                    value: bin.as_slice().to_vec().into(),
                })),
            }
        }
        TermType::List => {
            let items: Vec<Term> = term
                .decode()
                .map_err(|_| NifError::argument("invalid list"))?;
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                out.push(decode_bolt(item)?);
            }
            Ok(BoltType::List(BoltList { value: out }))
        }
        TermType::Map => decode_map_term(term),
        TermType::Tuple => decode_tuple(term),
        other => Err(NifError::argument(format!(
            "unsupported term type: {:?}",
            other
        ))),
    }
}

fn decode_atom(term: Term) -> Result<BoltType, NifError> {
    let name = term
        .atom_to_string()
        .map_err(|_| NifError::argument("invalid atom"))?;
    match name.as_str() {
        "nil" => Ok(BoltType::Null(BoltNull)),
        "true" => Ok(BoltType::Boolean(BoltBoolean { value: true })),
        "false" => Ok(BoltType::Boolean(BoltBoolean { value: false })),
        other => Err(NifError::argument(format!("unsupported atom: {}", other))),
    }
}

fn decode_tuple(term: Term) -> Result<BoltType, NifError> {
    let elems = tuple::get_tuple(term).map_err(|_| NifError::argument("invalid tuple"))?;
    if elems.len() == 2 {
        let tag = elems[0]
            .atom_to_string()
            .map_err(|_| NifError::argument("tagged tuple must start with an atom"))?;
        if tag == "bytes" {
            let bin: Binary = elems[1]
                .decode()
                .map_err(|_| NifError::argument("bytes payload must be a binary"))?;
            return Ok(BoltType::Bytes(BoltBytes {
                value: bin.as_slice().to_vec().into(),
            }));
        }
    }
    Err(NifError::argument("unsupported tuple value"))
}

fn decode_map_term(term: Term) -> Result<BoltType, NifError> {
    let env = term.get_env();
    let struct_key = atoms::struct_key().encode(env);
    if let Ok(module_term) = term.map_get(struct_key) {
        let module = module_term
            .atom_to_string()
            .map_err(|_| NifError::argument("__struct__ must be an atom"))?;
        return decode_struct(term, &module);
    }
    decode_plain_map(term)
}

fn decode_plain_map(term: Term) -> Result<BoltType, NifError> {
    let iter = MapIterator::new(term).ok_or_else(|| NifError::argument("expected map"))?;
    let mut out: HashMap<BoltString, BoltType> = HashMap::new();
    for (k, v) in iter {
        let key = decode_map_key(k)?;
        let val = decode_bolt(v)?;
        out.insert(BoltString { value: key }, val);
    }
    Ok(BoltType::Map(BoltMap { value: out }))
}

fn decode_map_key(term: Term) -> Result<String, NifError> {
    if let Ok(s) = term.decode::<String>() {
        return Ok(s);
    }
    if let Ok(a) = term.atom_to_string() {
        return Ok(a);
    }
    Err(NifError::argument("map keys must be atoms or strings"))
}

fn get_field<'a>(term: Term<'a>, key: Atom) -> Result<Term<'a>, NifError> {
    let env = term.get_env();
    term.map_get(key.encode(env))
        .map_err(|_| NifError::argument(format!("missing field: {:?}", key)))
}

fn field_i64(term: Term, key: Atom) -> Result<i64, NifError> {
    get_field(term, key)?
        .decode::<i64>()
        .map_err(|_| NifError::argument(format!("field {:?} must be integer", key)))
}

fn field_u32(term: Term, key: Atom) -> Result<u32, NifError> {
    let n = field_i64(term, key)?;
    if n < 0 || n > u32::MAX as i64 {
        return Err(NifError::argument(format!(
            "field {:?} out of u32 range",
            key
        )));
    }
    Ok(n as u32)
}

fn field_i32(term: Term, key: Atom) -> Result<i32, NifError> {
    let n = field_i64(term, key)?;
    if n < i32::MIN as i64 || n > i32::MAX as i64 {
        return Err(NifError::argument(format!(
            "field {:?} out of i32 range",
            key
        )));
    }
    Ok(n as i32)
}

fn field_string(term: Term, key: Atom) -> Result<String, NifError> {
    get_field(term, key)?
        .decode::<String>()
        .map_err(|_| NifError::argument(format!("field {:?} must be a string", key)))
}

fn decode_microsecond_field(term: Term) -> Result<u32, NifError> {
    let us_term = get_field(term, atoms::microsecond())?;
    let (us, _precision): (i64, i64) = us_term
        .decode()
        .map_err(|_| NifError::argument("microsecond must be {integer, precision}"))?;
    if us < 0 || us > 999_999 {
        return Err(NifError::argument("microsecond out of range"));
    }
    Ok(us as u32)
}

fn decode_elx_date(term: Term) -> Result<NaiveDate, NifError> {
    let year = field_i32(term, atoms::year())?;
    let month = field_u32(term, atoms::month())?;
    let day = field_u32(term, atoms::day())?;
    NaiveDate::from_ymd_opt(year, month, day)
        .ok_or_else(|| NifError::argument(format!("invalid date {}-{}-{}", year, month, day)))
}

fn decode_elx_time(term: Term) -> Result<NaiveTime, NifError> {
    let hour = field_u32(term, atoms::hour())?;
    let minute = field_u32(term, atoms::minute())?;
    let second = field_u32(term, atoms::second())?;
    let micros = decode_microsecond_field(term)?;
    NaiveTime::from_hms_micro_opt(hour, minute, second, micros)
        .ok_or_else(|| NifError::argument("invalid time components"))
}

fn decode_elx_naive_datetime(term: Term) -> Result<NaiveDateTime, NifError> {
    let d = decode_elx_date(term)?;
    let t = decode_elx_time(term)?;
    Ok(d.and_time(t))
}

fn decode_struct(term: Term, module: &str) -> Result<BoltType, NifError> {
    match module {
        "Elixir.Date" => Ok(BoltType::Date(decode_elx_date(term)?.into())),
        "Elixir.Time" => Ok(BoltType::LocalTime(decode_elx_time(term)?.into())),
        "Elixir.NaiveDateTime" => Ok(BoltType::LocalDateTime(
            decode_elx_naive_datetime(term)?.into(),
        )),
        "Elixir.DateTime" => {
            let naive = decode_elx_naive_datetime(term)?;
            let utc_off = field_i32(term, atoms::utc_offset())?;
            let std_off = field_i32(term, atoms::std_offset())?;
            let offset = FixedOffset::east_opt(utc_off + std_off)
                .ok_or_else(|| NifError::argument("invalid timezone offset"))?;
            let dt = offset
                .from_local_datetime(&naive)
                .single()
                .ok_or_else(|| NifError::argument("ambiguous/invalid local datetime"))?;
            Ok(BoltType::DateTime(dt.into()))
        }
        "Elixir.BoltexNif.Node" => {
            let id = field_i64(term, atoms::id())?;
            let labels_t = get_field(term, atoms::labels())?;
            let labels_vec: Vec<String> = labels_t
                .decode()
                .map_err(|_| NifError::argument("labels must be a list of strings"))?;
            let props_t = get_field(term, atoms::properties())?;
            let props = match decode_bolt(props_t)? {
                BoltType::Map(m) => m,
                _ => return Err(NifError::argument("properties must be a map")),
            };
            let labels_bolt = BoltList {
                value: labels_vec
                    .into_iter()
                    .map(|s| BoltType::String(BoltString { value: s }))
                    .collect(),
            };
            Ok(BoltType::Node(BoltNode {
                id: BoltInteger { value: id },
                labels: labels_bolt,
                properties: props,
            }))
        }
        "Elixir.BoltexNif.Relationship" => {
            let id = field_i64(term, atoms::id())?;
            let start = field_i64(term, atoms::start_node_id())?;
            let end = field_i64(term, atoms::end_node_id())?;
            let typ = field_string(term, atoms::type_key())?;
            let props_t = get_field(term, atoms::properties())?;
            let props = match decode_bolt(props_t)? {
                BoltType::Map(m) => m,
                _ => return Err(NifError::argument("properties must be a map")),
            };
            Ok(BoltType::Relation(BoltRelation {
                id: BoltInteger { value: id },
                start_node_id: BoltInteger { value: start },
                end_node_id: BoltInteger { value: end },
                typ: BoltString { value: typ },
                properties: props,
            }))
        }
        "Elixir.BoltexNif.UnboundRelationship" => {
            let id = field_i64(term, atoms::id())?;
            let typ = field_string(term, atoms::type_key())?;
            let props_t = get_field(term, atoms::properties())?;
            let props = match decode_bolt(props_t)? {
                BoltType::Map(m) => m,
                _ => return Err(NifError::argument("properties must be a map")),
            };
            Ok(BoltType::UnboundedRelation(BoltUnboundedRelation {
                id: BoltInteger { value: id },
                typ: BoltString { value: typ },
                properties: props,
            }))
        }
        "Elixir.BoltexNif.Point" => {
            let srid = field_i64(term, atoms::srid())?;
            let x: f64 = get_field(term, atoms::x())?
                .decode()
                .map_err(|_| NifError::argument("x must be float"))?;
            let y: f64 = get_field(term, atoms::y())?
                .decode()
                .map_err(|_| NifError::argument("y must be float"))?;
            let z_term = get_field(term, atoms::z())?;
            if let Ok(z) = z_term.decode::<f64>() {
                Ok(BoltType::Point3D(BoltPoint3D {
                    sr_id: BoltInteger { value: srid },
                    x: BoltFloat { value: x },
                    y: BoltFloat { value: y },
                    z: BoltFloat { value: z },
                }))
            } else {
                // nil or missing -> 2D
                Ok(BoltType::Point2D(BoltPoint2D {
                    sr_id: BoltInteger { value: srid },
                    x: BoltFloat { value: x },
                    y: BoltFloat { value: y },
                }))
            }
        }
        "Elixir.BoltexNif.Duration" => {
            let months = field_i64(term, atoms::months())?;
            let days = field_i64(term, atoms::days())?;
            let seconds = field_i64(term, atoms::seconds())?;
            let nanos = field_i64(term, atoms::nanoseconds())?;
            Ok(BoltType::Duration(BoltDuration::new(
                BoltInteger { value: months },
                BoltInteger { value: days },
                BoltInteger { value: seconds },
                BoltInteger { value: nanos },
            )))
        }
        "Elixir.BoltexNif.Time" => {
            let time_t = get_field(term, atoms::time())?;
            let nt = decode_elx_time(time_t)?;
            let off = field_i32(term, atoms::offset_seconds())?;
            let offset = FixedOffset::east_opt(off)
                .ok_or_else(|| NifError::argument("invalid time offset"))?;
            Ok(BoltType::Time(BoltTime::from((nt, offset))))
        }
        "Elixir.BoltexNif.DateTime" => {
            let naive_t = get_field(term, atoms::naive())?;
            let naive = decode_elx_naive_datetime(naive_t)?;
            let off = field_i32(term, atoms::offset_seconds())?;
            let offset = FixedOffset::east_opt(off)
                .ok_or_else(|| NifError::argument("invalid datetime offset"))?;
            let dt = offset
                .from_local_datetime(&naive)
                .single()
                .ok_or_else(|| NifError::argument("ambiguous local datetime"))?;
            Ok(BoltType::DateTime(dt.into()))
        }
        "Elixir.BoltexNif.DateTimeZoneId" => {
            let naive_t = get_field(term, atoms::naive())?;
            let naive = decode_elx_naive_datetime(naive_t)?;
            let tz_id = field_string(term, atoms::tz_id())?;
            // `From<(NaiveDateTime, &str)> for BoltDateTimeZoneId`
            let bdtz: BoltDateTimeZoneId = (naive, tz_id.as_str()).into();
            Ok(BoltType::DateTimeZoneId(bdtz))
        }
        other => Err(NifError::argument(format!("unsupported struct: {}", other))),
    }
}

// Re-export the chrono `TimeZone` trait locally so callers can use `.from_local_datetime`.
use chrono::TimeZone as _;

// =======================================================================
// Param map decoding (top-level %{String => BoltType}).
// =======================================================================

pub fn decode_params(term: Term) -> Result<Vec<(String, BoltType)>, NifError> {
    if term.is_atom() {
        // Allow nil for "no params".
        if let Ok(name) = term.atom_to_string() {
            if name == "nil" {
                return Ok(Vec::new());
            }
        }
    }
    if term.get_type() != TermType::Map {
        return Err(NifError::argument("params must be a map"));
    }
    let iter = MapIterator::new(term).ok_or_else(|| NifError::argument("expected map"))?;
    let mut out = Vec::new();
    for (k, v) in iter {
        let key = decode_map_key(k)?;
        let val = decode_bolt(v)?;
        out.push((key, val));
    }
    Ok(out)
}
