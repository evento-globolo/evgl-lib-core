import evgl_validation.{type RequestMeta}
import gleam/dynamic/decode
import gleam/option.{type Option, None}

pub type TrustedActor {
  TrustedActor(user_id: String, tenant_id: Option(String), roles: List(String))
}

pub type ServerRequestContext {
  ServerRequestContext(public: RequestMeta, actor: TrustedActor, source_ip: Option(String))
}

pub fn trusted_actor_decoder() -> decode.Decoder(TrustedActor) {
  use user_id <- decode.field("userId", decode.string)
  use tenant_id <- decode.optional_field("tenantId", None, decode.optional(decode.string))
  use roles <- decode.field("roles", decode.list(decode.string))
  decode.success(TrustedActor(user_id: user_id, tenant_id: tenant_id, roles: roles))
}

pub fn server_request_context_decoder() -> decode.Decoder(ServerRequestContext) {
  use public <- decode.field("public", evgl_validation.request_meta_decoder())
  use actor <- decode.field("actor", trusted_actor_decoder())
  use source_ip <- decode.optional_field("sourceIp", None, decode.optional(decode.string))
  decode.success(ServerRequestContext(public: public, actor: actor, source_ip: source_ip))
}
