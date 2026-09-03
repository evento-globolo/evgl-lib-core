#![forbid(unsafe_code)]

use evgl_validation::RequestMeta;
use garde::Validate;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, Validate)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrustedActor {
    #[garde(length(min = 1, max = 128))]
    pub user_id: String,
    #[garde(length(min = 1, max = 128))]
    pub tenant_id: Option<String>,
    #[garde(length(max = 64), inner(length(min = 1, max = 128)))]
    pub roles: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Validate)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServerRequestContext {
    #[garde(dive)]
    pub public: RequestMeta,
    #[garde(dive)]
    pub actor: TrustedActor,
    #[garde(ip)]
    pub source_ip: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Validate)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InternalCommand {
    #[garde(length(min = 1, max = 256))]
    pub operation_id: String,
    #[garde(length(min = 1, max = 128))]
    pub idempotency_key: Option<String>,
    #[garde(dive)]
    pub context: ServerRequestContext,
    #[garde(skip)]
    pub payload: serde_json::Value,
}
