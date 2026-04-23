//! Global Tokio runtime plus a helper that turns an async computation into a
//! non-blocking NIF: the call returns a fresh `ref` immediately; when the
//! future resolves, the result is sent back to the calling process as
//! `{ref, term}` via `OwnedEnv::send_and_clear`.

use std::future::Future;

use once_cell::sync::Lazy;
use rustler::{Encoder, Env, OwnedEnv, Term};
use tokio::runtime::{Builder, Runtime};

static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    Builder::new_multi_thread()
        .enable_all()
        .thread_name("boltex-nif-tokio")
        .build()
        .expect("boltex_nif: failed to build tokio runtime")
});

/// Type-erased closure that builds the reply term inside the target `Env`.
pub struct Response(Box<dyn for<'a> FnOnce(Env<'a>) -> Term<'a> + Send + 'static>);

impl Response {
    pub fn new<F>(f: F) -> Self
    where
        F: for<'a> FnOnce(Env<'a>) -> Term<'a> + Send + 'static,
    {
        Response(Box::new(f))
    }

    fn into_term<'a>(self, env: Env<'a>) -> Term<'a> {
        (self.0)(env)
    }
}

/// Spawn `fut` on the global runtime. When it completes, send
/// `{ref, response_term}` to the calling PID. Returns the `ref` synchronously.
pub fn spawn<'a, F>(env: Env<'a>, fut: F) -> Term<'a>
where
    F: Future<Output = Response> + Send + 'static,
{
    let reference = env.make_ref();
    let ref_term: Term<'a> = reference.encode(env);
    let pid = env.pid();
    let mut owned = OwnedEnv::new();
    let saved_ref = owned.save(ref_term);

    RUNTIME.spawn(async move {
        let response = fut.await;
        let _ = owned.send_and_clear(&pid, move |env| {
            let r = saved_ref.load(env);
            let v = response.into_term(env);
            (r, v).encode(env)
        });
    });

    ref_term
}
