use rustler::{Atom, Encoder, Env, Term};

use crate::atoms;

/// Typed error surfaced to Elixir as `{kind, payload}`.
#[derive(Debug)]
pub struct NifError {
    pub kind: ErrorKind,
    pub payload: ErrorPayload,
}

#[derive(Debug, Clone, Copy)]
pub enum ErrorKind {
    InvalidConfig,
    Io,
    Neo4j,
    Deserialization,
    UnexpectedType,
    Unexpected,
    Argument,
}

#[derive(Debug)]
pub enum ErrorPayload {
    Message(String),
    Neo4jError {
        code: String,
        message: String,
        kind: Neo4jKind,
    },
}

#[derive(Debug, Clone, Copy)]
pub enum Neo4jKind {
    Authentication,
    AuthorizationExpired,
    TokenExpired,
    OtherSecurity,
    SessionExpired,
    FatalDiscovery,
    TransactionTerminated,
    ProtocolViolation,
    ClientOther,
    ClientUnknown,
    Transient,
    Database,
    Unknown,
}

impl ErrorKind {
    fn to_atom(self) -> Atom {
        match self {
            ErrorKind::InvalidConfig => atoms::invalid_config(),
            ErrorKind::Io => atoms::io(),
            ErrorKind::Neo4j => atoms::neo4j(),
            ErrorKind::Deserialization => atoms::deserialization(),
            ErrorKind::UnexpectedType => atoms::unexpected_type(),
            ErrorKind::Unexpected => atoms::unexpected(),
            ErrorKind::Argument => atoms::argument(),
        }
    }
}

impl Neo4jKind {
    fn to_atom(self) -> Atom {
        match self {
            Neo4jKind::Authentication => atoms::authentication(),
            Neo4jKind::AuthorizationExpired => atoms::authorization_expired(),
            Neo4jKind::TokenExpired => atoms::token_expired(),
            Neo4jKind::OtherSecurity => atoms::other_security(),
            Neo4jKind::SessionExpired => atoms::session_expired(),
            Neo4jKind::FatalDiscovery => atoms::fatal_discovery(),
            Neo4jKind::TransactionTerminated => atoms::transaction_terminated(),
            Neo4jKind::ProtocolViolation => atoms::protocol_violation(),
            Neo4jKind::ClientOther => atoms::client_other(),
            Neo4jKind::ClientUnknown => atoms::client_unknown(),
            Neo4jKind::Transient => atoms::transient(),
            Neo4jKind::Database => atoms::database(),
            Neo4jKind::Unknown => atoms::unknown(),
        }
    }
}

impl NifError {
    pub fn argument(msg: impl Into<String>) -> Self {
        NifError {
            kind: ErrorKind::Argument,
            payload: ErrorPayload::Message(msg.into()),
        }
    }

    pub fn encode_term<'a>(self, env: Env<'a>) -> Term<'a> {
        let kind_atom = self.kind.to_atom();
        match self.payload {
            ErrorPayload::Message(m) => (kind_atom, m).encode(env),
            ErrorPayload::Neo4jError {
                code,
                message,
                kind,
            } => {
                let struct_t = build_neo4j_struct(env, code, message, kind);
                (kind_atom, struct_t).encode(env)
            }
        }
    }
}

fn build_neo4j_struct<'a>(
    env: Env<'a>,
    code: String,
    message: String,
    kind: Neo4jKind,
) -> Term<'a> {
    let mut map = Term::map_new(env);
    map = map
        .map_put(
            atoms::struct_key().encode(env),
            atoms::neo4j_error_module().encode(env),
        )
        .expect("map_put struct");
    map = map
        .map_put(atoms::code().encode(env), code.encode(env))
        .expect("map_put code");
    map = map
        .map_put(atoms::message().encode(env), message.encode(env))
        .expect("map_put message");
    map = map
        .map_put(atoms::kind().encode(env), kind.to_atom().encode(env))
        .expect("map_put kind");
    map
}

fn classify_neo4j_kind(k: neo4rs::Neo4jErrorKind) -> Neo4jKind {
    use neo4rs::{Neo4jClientErrorKind, Neo4jErrorKind, Neo4jSecurityErrorKind};
    match k {
        Neo4jErrorKind::Client(c) => match c {
            Neo4jClientErrorKind::Security(s) => match s {
                Neo4jSecurityErrorKind::Authentication => Neo4jKind::Authentication,
                Neo4jSecurityErrorKind::AuthorizationExpired => Neo4jKind::AuthorizationExpired,
                Neo4jSecurityErrorKind::TokenExpired => Neo4jKind::TokenExpired,
                Neo4jSecurityErrorKind::Other => Neo4jKind::OtherSecurity,
                Neo4jSecurityErrorKind::Unknown => Neo4jKind::OtherSecurity,
            },
            Neo4jClientErrorKind::SessionExpired => Neo4jKind::SessionExpired,
            Neo4jClientErrorKind::FatalDiscovery => Neo4jKind::FatalDiscovery,
            Neo4jClientErrorKind::TransactionTerminated => Neo4jKind::TransactionTerminated,
            Neo4jClientErrorKind::ProtocolViolation => Neo4jKind::ProtocolViolation,
            Neo4jClientErrorKind::Other => Neo4jKind::ClientOther,
            Neo4jClientErrorKind::Unknown => Neo4jKind::ClientUnknown,
        },
        Neo4jErrorKind::Transient => Neo4jKind::Transient,
        Neo4jErrorKind::Database => Neo4jKind::Database,
        Neo4jErrorKind::Unknown => Neo4jKind::Unknown,
    }
}

impl From<neo4rs::Error> for NifError {
    fn from(e: neo4rs::Error) -> Self {
        use neo4rs::Error;

        if let Error::Neo4j(n4j) = &e {
            return NifError {
                kind: ErrorKind::Neo4j,
                payload: ErrorPayload::Neo4jError {
                    code: n4j.code().to_string(),
                    message: n4j.message().to_string(),
                    kind: classify_neo4j_kind(n4j.kind()),
                },
            };
        }

        let kind = match &e {
            Error::IOError { .. } | Error::ConnectionError => ErrorKind::Io,
            Error::UrlParseError(_)
            | Error::UnsupportedScheme(_)
            | Error::InvalidDnsName(_)
            | Error::InvalidConfig => ErrorKind::InvalidConfig,
            Error::AuthenticationError(_) => ErrorKind::Neo4j,
            Error::DeserializationError(_) => ErrorKind::Deserialization,
            Error::UnexpectedMessage(_)
            | Error::UnknownType(_)
            | Error::UnknownMessage(_)
            | Error::UnsupportedVersion(_, _)
            | Error::ProtocolMismatch(_)
            | Error::InvalidTypeMarker(_)
            | Error::ConversionError => ErrorKind::UnexpectedType,
            _ => ErrorKind::Unexpected,
        };
        NifError {
            kind,
            payload: ErrorPayload::Message(e.to_string()),
        }
    }
}
