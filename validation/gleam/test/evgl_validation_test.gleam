import evgl_validation
import gleam/dynamic
import gleeunit
import gleeunit/should

pub fn main() { gleeunit.main() }

pub fn request_meta_decoder_rejects_missing_trace_id_test() {
  dynamic.properties([#(dynamic.string("requestId"), dynamic.string("req-1"))])
  |> evgl_validation.decode_request_meta
  |> should.be_error
}
