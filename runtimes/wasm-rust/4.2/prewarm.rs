// Compiled once while the build image is built, so the dependencies of the default Cargo.toml are
// in CARGO_TARGET_DIR before any function build.
use spin_sdk::http::IntoResponse;
use spin_sdk::http_service;

#[http_service]
async fn handle(_req: spin_sdk::http::Request) -> impl IntoResponse {
    "prewarm"
}
