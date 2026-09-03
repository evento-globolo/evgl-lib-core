import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option, None}

pub const contract_version = "ores.validation.v1"

pub type RequestMeta {
  RequestMeta(request_id: String, trace_id: String, locale: Option(String))
}

pub type PageQuery {
  PageQuery(limit: Int, cursor: Option(String))
}

pub type ProblemDetails {
  ProblemDetails(type_: String, title: String, status: Int, detail: Option(String), request_id: String)
}

pub fn request_meta_decoder() -> decode.Decoder(RequestMeta) {
  use request_id <- decode.field("requestId", non_empty_string())
  use trace_id <- decode.field("traceId", non_empty_string())
  use locale <- decode.optional_field("locale", None, decode.optional(non_empty_string()))
  decode.success(RequestMeta(request_id: request_id, trace_id: trace_id, locale: locale))
}

pub fn page_query_decoder() -> decode.Decoder(PageQuery) {
  use limit <- decode.field("limit", bounded_int(1, 100))
  use cursor <- decode.optional_field("cursor", None, decode.optional(non_empty_string()))
  decode.success(PageQuery(limit: limit, cursor: cursor))
}

pub fn problem_details_decoder() -> decode.Decoder(ProblemDetails) {
  use type_ <- decode.field("type", non_empty_string())
  use title <- decode.field("title", non_empty_string())
  use status <- decode.field("status", bounded_int(400, 599))
  use detail <- decode.optional_field("detail", None, decode.optional(decode.string))
  use request_id <- decode.field("requestId", non_empty_string())
  decode.success(ProblemDetails(type_: type_, title: title, status: status, detail: detail, request_id: request_id))
}

pub fn decode_request_meta(value: Dynamic) { decode.run(value, request_meta_decoder()) }

fn non_empty_string() -> decode.Decoder(String) {
  decode.string
  |> decode.then(fn(value) {
    case value == "" {
      True -> decode.failure("", expected: "non-empty String")
      False -> decode.success(value)
    }
  })
}

fn bounded_int(min: Int, max: Int) -> decode.Decoder(Int) {
  decode.int
  |> decode.then(fn(value) {
    case value >= min && value <= max {
      True -> decode.success(value)
      False -> decode.failure(0, expected: "bounded Int")
    }
  })
}
