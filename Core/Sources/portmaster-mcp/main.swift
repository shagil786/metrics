// The whole executable: hand the MCP server the production context and serve it.
//
// Everything else — the catalog on the wire, the argument coercion, the
// per-call permission gate, and the run loop the sampler needs — lives in
// `PortmasterMCP`, where it can be tested without spawning a process.
//
// stdout is MCP's. This file writes nothing to it.
import PortmasterMCP

MCPStdioRunner.runMain()