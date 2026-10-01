// MCP stdio JSON-RPC 서버 (speak + install 도구)
use crate::debrief_version::DebriefVersion;
use crate::mcp_speak_tool::McpToolCallResult;
use serde_json::{json, Value};

/// 순수 JSON-RPC 메소드 디스패치 (FileHandle 없이 테스트 가능).
pub struct McpJsonRpc;

impl McpJsonRpc {
    pub fn handle(request: &Value, call_tool: impl Fn(&str, &serde_json::Map<String, Value>) -> McpToolCallResult) -> Option<Value> {
        let Value::Object(request) = request else { return None };
        let method = request.get("method").and_then(|v| v.as_str());
        let id = request.get("id").cloned();

        // 알림(id 없음)은 응답 본문이 없다.
        let id = id?;

        let Some(method) = method else {
            return Some(Self::error_response(Some(id), -32600, "Invalid Request"));
        };

        match method {
            "initialize" => {
                let default_params = serde_json::Map::new();
                let params = request.get("params").and_then(|v| v.as_object()).unwrap_or(&default_params);
                let protocol_version = params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or("2024-11-05");
                Some(Self::success_response(
                    Some(id),
                    json!({
                        "protocolVersion": protocol_version,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "debrief", "version": DebriefVersion::CURRENT},
                    }),
                ))
            }
            "notifications/initialized" => None,
            "tools/list" => Some(Self::success_response(
                Some(id),
                json!({"tools": [Self::speak_tool_definition(), Self::install_tool_definition()]}),
            )),
            "tools/call" => {
                let empty = serde_json::Map::new();
                let params = request.get("params").and_then(|v| v.as_object()).unwrap_or(&empty);
                let name = params.get("name").and_then(|v| v.as_str());
                let Some(name) = name.filter(|n| *n == "speak" || *n == "install") else {
                    return Some(Self::error_response(
                        Some(id),
                        -32601,
                        &format!("Method not found: tool {}", name.unwrap_or("(nil)")),
                    ));
                };
                let arguments = params.get("arguments").and_then(|v| v.as_object()).cloned().unwrap_or_default();
                let tool_result = call_tool(name, &arguments);
                Some(Self::success_response(
                    Some(id),
                    json!({
                        "content": [{"type": "text", "text": tool_result.message}],
                        "isError": tool_result.is_error,
                    }),
                ))
            }
            "ping" => Some(Self::success_response(Some(id), json!({}))),
            other => Some(Self::error_response(Some(id), -32601, &format!("Method not found: {other}"))),
        }
    }

    fn speak_tool_definition() -> Value {
        json!({
            "name": "speak",
            "description":
                "At the end of each user-visible turn, speak once: two short sentences — what changed, then the one next action. \
The agent writes the line. Silence only if nothing new. \
lane=companion rotates one voice per session across F1–M5 (pass session to keep it) or work uses the voice you pass; emotion biases prosody only. \
On Claude Code: mcp__debrief__speak; on Grok: debrief__speak (search_tool/use_tool). \
Do not put HTML comments or JSON speech metadata in the assistant message body.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "voice": {"type": "string"},
                    "speed": {"type": "number"},
                    "volume": {"type": "number"},
                    "priority": {
                        "type": "string",
                        "description": "main (default) or subagent; focus/quiet/night suppress subagent",
                        "enum": ["main", "subagent"],
                    },
                    "lane": {
                        "type": "string",
                        "description": "companion (default briefing) or work (factual report)",
                        "enum": ["companion", "work"],
                    },
                    "emotion": {
                        "type": "string",
                        "description": "restrained affect for companion: neutral (default), warm, focused, concerned, relieved, tired",
                        "enum": ["neutral", "warm", "focused", "concerned", "relieved", "tired"],
                    },
                    "session": {
                        "type": "string",
                        "description": "Host session id. Companion voice rotates across F1–M5 and stays on this id. Omit to use this MCP process.",
                    },
                },
                "required": ["text", "voice", "speed", "volume"],
            },
        })
    }

    fn install_tool_definition() -> Value {
        json!({
            "name": "install",
            "description":
                "Install or repair the debrief daemon (MCP registration, start-family hooks, skills, LaunchAgent). \
On Claude Code this may appear as mcp__debrief__install; on Grok as debrief__install (search_tool / use_tool). \
Prefer repair=true for fixes. First-time model download can be slow — use shell install if the tool times out. \
After install: Claude restart; Grok run /mcps to refresh tools.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "hosts": {
                        "type": "array",
                        "description": "Hosts to wire: codex, claude, grok. Omit for all.",
                        "items": {"type": "string", "enum": ["codex", "claude", "grok"]},
                    },
                    "repair": {
                        "type": "boolean",
                        "description": "Reinstall owned files and re-verify model (default true).",
                    },
                },
                "required": [],
            },
        })
    }

    fn success_response(id: Option<Value>, result: Value) -> Value {
        json!({"jsonrpc": "2.0", "id": id.unwrap_or(Value::Null), "result": result})
    }

    pub fn parse_error_response() -> Value {
        Self::error_response(None, -32700, "Parse error")
    }

    fn error_response(id: Option<Value>, code: i64, message: &str) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": id.unwrap_or(Value::Null),
            "error": {"code": code, "message": message},
        })
    }
}

/// Content-Length 프레이밍 한도 (FrameReader와 공유).
pub struct McpFraming;

impl McpFraming {
    pub const MAX_CONTENT_LENGTH: i64 = 1_000_000;

    pub fn validated_content_length(length: i64) -> Option<i64> {
        if (0..=Self::MAX_CONTENT_LENGTH).contains(&length) {
            Some(length)
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum McpWireFormat {
    ContentLength,
    NewlineDelimited,
}

/// stdio 프레임 하나(Content-Length 헤더가 있는 블록 또는 한 줄 NDJSON).
pub struct Frame {
    pub body: Vec<u8>,
    pub format: McpWireFormat,
}

/// stdin 스트림에서 MCP 프레임을 누적·추출하는 버퍼드 리더.
pub struct FrameReader<R: std::io::Read> {
    reader: R,
    buffer: Vec<u8>,
}

impl<R: std::io::Read> FrameReader<R> {
    pub fn new(reader: R) -> Self {
        FrameReader { reader, buffer: Vec::new() }
    }

    pub fn read_frame(&mut self) -> Option<Frame> {
        loop {
            if let Some(frame) = self.try_extract_frame() {
                return Some(frame);
            }
            let mut chunk = [0u8; 4096];
            let n = loop {
                match self.reader.read(&mut chunk) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => return None,
                }
            };
            if n == 0 {
                return None;
            }
            self.buffer.extend_from_slice(&chunk[..n]);
        }
    }

    fn try_extract_frame(&mut self) -> Option<Frame> {
        self.skip_leading_whitespace();
        let first = *self.buffer.first()?;

        if first == b'{' || first == b'[' {
            let nl = self.buffer.iter().position(|&b| b == b'\n')?;
            let body_end = if nl > 0 && self.buffer[nl - 1] == b'\r' { nl - 1 } else { nl };
            let body = self.buffer[..body_end].to_vec();
            self.buffer.drain(..=nl);
            if body.is_empty() {
                return None;
            }
            return Some(Frame { body, format: McpWireFormat::NewlineDelimited });
        }

        let header_end = Self::index_of_header_terminator(&self.buffer)?;
        let header_data = &self.buffer[..header_end];
        let body_start = header_end + 4;
        let Some(length) = Self::content_length_from(header_data) else {
            self.buffer.clear();
            return None;
        };
        let length = length as usize;
        if self.buffer.len() < body_start + length {
            return None;
        }
        let body = self.buffer[body_start..body_start + length].to_vec();
        self.buffer.drain(..body_start + length);
        Some(Frame { body, format: McpWireFormat::ContentLength })
    }

    fn skip_leading_whitespace(&mut self) {
        let mut i = 0;
        while i < self.buffer.len() {
            match self.buffer[i] {
                0x20 | 0x09 | 0x0A | 0x0D => i += 1,
                _ => break,
            }
        }
        if i > 0 {
            self.buffer.drain(..i);
        }
    }

    fn index_of_header_terminator(data: &[u8]) -> Option<usize> {
        let pattern = [0x0D, 0x0A, 0x0D, 0x0A];
        data.windows(4).position(|window| window == pattern)
    }

    fn content_length_from(header_data: &[u8]) -> Option<i64> {
        let header = std::str::from_utf8(header_data).ok()?;
        for line in header.lines() {
            let trimmed = line.trim();
            let Some(colon) = trimmed.find(':') else { continue };
            let name = trimmed[..colon].trim().to_lowercase();
            if name != "content-length" {
                continue;
            }
            let value = trimmed[colon + 1..].trim();
            let raw: i64 = value.parse().ok()?;
            return McpFraming::validated_content_length(raw);
        }
        None
    }
}

pub fn write_frame<W: std::io::Write>(output: &mut W, value: &Value, format: McpWireFormat) {
    let Ok(mut data) = serde_json::to_vec(value) else { return };
    match format {
        McpWireFormat::ContentLength => {
            let header = format!("Content-Length: {}\r\n\r\n", data.len());
            let _ = output.write_all(header.as_bytes());
            let _ = output.write_all(&data);
        }
        McpWireFormat::NewlineDelimited => {
            data.push(b'\n');
            let _ = output.write_all(&data);
        }
    }
    let _ = output.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_returns_server_info() {
        let req = json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}},
        });
        let res = McpJsonRpc::handle(&req, |_, _| McpToolCallResult { is_error: true, message: "no".to_string() }).unwrap();
        assert!(res["result"]["protocolVersion"].is_string());
        assert_eq!(res["result"]["serverInfo"]["name"], "debrief");
    }

    #[test]
    fn tools_list_contains_speak_and_install() {
        let req = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}});
        let res = McpJsonRpc::handle(&req, |_, _| McpToolCallResult { is_error: false, message: String::new() }).unwrap();
        let tools = res["result"]["tools"].as_array().unwrap();
        assert!(tools.iter().any(|t| t["name"] == "speak"));
        assert!(tools.iter().any(|t| t["name"] == "install"));
        let description = tools.iter().find(|t| t["name"] == "speak").unwrap()["description"].as_str().unwrap();
        assert!(description.contains("what changed"));
        assert!(description.contains("next action"));
        assert!(!description.to_lowercase().contains("debrief summarizes"));
    }

    #[test]
    fn tools_call_install_invokes_handler() {
        let req = json!({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "install", "arguments": {"hosts": ["claude"], "repair": true}},
        });
        let seen = std::cell::RefCell::new(String::new());
        let res = McpJsonRpc::handle(&req, |name, args| {
            *seen.borrow_mut() = name.to_string();
            assert_eq!(args.get("hosts").unwrap(), &json!(["claude"]));
            McpToolCallResult { is_error: false, message: "{\"ok\":true}".to_string() }
        })
        .unwrap();
        assert_eq!(*seen.borrow(), "install");
        assert_eq!(res["result"]["isError"], false);
    }

    #[test]
    fn tools_call_speak_invokes_handler() {
        let req = json!({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "speak", "arguments": {"text": "hi", "voice": "F1", "speed": 1.0, "volume": 0.5}},
        });
        let seen = std::cell::RefCell::new(None);
        let res = McpJsonRpc::handle(&req, |_, args| {
            *seen.borrow_mut() = args.get("text").and_then(|v| v.as_str()).map(|s| s.to_string());
            McpToolCallResult { is_error: false, message: "{\"ok\":true}".to_string() }
        })
        .unwrap();
        assert_eq!(seen.borrow().as_deref(), Some("hi"));
        assert_eq!(res["result"]["isError"], false);
    }

    #[test]
    fn notifications_return_nil_response() {
        let req = json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
        let res = McpJsonRpc::handle(&req, |_, _| McpToolCallResult { is_error: false, message: String::new() });
        assert!(res.is_none());
    }

    #[test]
    fn parse_error_response_uses_code_32700_and_null_id() {
        let res = McpJsonRpc::parse_error_response();
        assert_eq!(res["jsonrpc"], "2.0");
        assert!(res["id"].is_null());
        assert_eq!(res["error"]["code"], -32700);
        assert_eq!(res["error"]["message"], "Parse error");
    }

    #[test]
    fn content_length_rejects_negative_and_absurd_large() {
        assert_eq!(McpFraming::validated_content_length(0), Some(0));
        assert_eq!(McpFraming::validated_content_length(42), Some(42));
        assert_eq!(McpFraming::validated_content_length(McpFraming::MAX_CONTENT_LENGTH), Some(McpFraming::MAX_CONTENT_LENGTH));
        assert_eq!(McpFraming::validated_content_length(-1), None);
        assert_eq!(McpFraming::validated_content_length(McpFraming::MAX_CONTENT_LENGTH + 1), None);
    }

    #[test]
    fn frame_reader_extracts_content_length_frame() {
        let body = br#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        let mut input = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
        input.extend_from_slice(body);
        let mut reader = FrameReader::new(std::io::Cursor::new(input));
        let frame = reader.read_frame().unwrap();
        assert_eq!(frame.format, McpWireFormat::ContentLength);
        assert_eq!(frame.body, body);
    }

    #[test]
    fn frame_reader_extracts_newline_delimited_frame() {
        let mut input = br#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.to_vec();
        input.push(b'\n');
        let mut reader = FrameReader::new(std::io::Cursor::new(input));
        let frame = reader.read_frame().unwrap();
        assert_eq!(frame.format, McpWireFormat::NewlineDelimited);
        assert_eq!(frame.body, br#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#);
    }
}
