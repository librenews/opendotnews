module Mcp
  class Dispatcher
    SUPPORTED_PROTOCOL_VERSIONS = %w[2026-07-28 2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    DEFAULT_PROTOCOL_VERSION = "2026-07-28"

    TOOL_CLASSES = [
      Mcp::Tools::SubscribeFeed,
      Mcp::Tools::UnsubscribeFeed,
      Mcp::Tools::ListSubscriptions,
      Mcp::Tools::ListFeedItems,
      Mcp::Tools::GetFeedItem,
      Mcp::Tools::SearchItems,
      Mcp::Tools::GetUpdates,
      Mcp::Tools::ImportOpml,
      Mcp::Tools::GetOpmlImportStatus,
      Mcp::Tools::ExportOpml,
      Mcp::Tools::PublishDocument,
      Mcp::Tools::GetDocument,
      Mcp::Tools::UpdateDocument,
      Mcp::Tools::ListDocuments,
      Mcp::Tools::DeleteDocument
    ].freeze

    TOOLS_BY_NAME = TOOL_CLASSES.index_by(&:tool_name).freeze

    def initialize(user:, token:)
      @user = user
      @token = token
    end

    # Returns [http_status, json_payload_or_nil]
    def call(rpc)
      unless rpc.is_a?(Hash) && rpc["jsonrpc"] == "2.0" && rpc["method"].is_a?(String)
        return [ :bad_request, jsonrpc_error(nil, -32600, "Invalid JSON-RPC 2.0 request") ]
      end

      id = rpc["id"]
      method = rpc["method"]
      params = rpc["params"].is_a?(Hash) ? rpc["params"] : {}

      # Notifications have no id and return 202 Accepted per MCP Streamable HTTP.
      if !rpc.key?("id") || method.start_with?("notifications/")
        return [ :accepted, nil ]
      end

      result = case method
      when "initialize"
        handle_initialize(params)
      when "ping"
        {}
      when "tools/list"
        handle_tools_list
      when "tools/call"
        handle_tools_call(params)
      else
        return [ :ok, jsonrpc_error(id, -32601, "Method not found: #{method}") ]
      end

      [ :ok, { jsonrpc: "2.0", id: id, result: result } ]
    rescue ToolError => e
      [ :ok, {
        jsonrpc: "2.0",
        id: id,
        result: {
          isError: true,
          content: [ { type: "text", text: JSON.generate(error_payload(e)) } ],
          structuredContent: error_payload(e)
        }
      } ]
    rescue StandardError => e
      Rails.logger.error("MCP internal error on #{rpc['method']}: #{e.class}: #{e.message}")
      [ :ok, jsonrpc_error(id, -32603, "Internal server error") ]
    end

    private

    def handle_initialize(params)
      requested = params["protocolVersion"].to_s
      version = SUPPORTED_PROTOCOL_VERSIONS.include?(requested) ? requested : DEFAULT_PROTOCOL_VERSION
      {
        protocolVersion: version,
        capabilities: {
          tools: { listChanged: false }
        },
        serverInfo: {
          name: "Open.News",
          version: "1.0.0-phase1"
        }
      }
    end

    def handle_tools_list
      { tools: TOOL_CLASSES.map(&:definition) }
    end

    def handle_tools_call(params)
      name = params["name"].to_s
      args = params["arguments"].is_a?(Hash) ? params["arguments"] : {}

      tool_class = TOOLS_BY_NAME[name]
      raise ToolError.new("unknown_tool", "Unknown tool: #{name}") unless tool_class

      required_scope = tool_class.required_scope
      unless token_has_scope?(required_scope)
        raise ToolError.new("forbidden", "Token missing required scope '#{required_scope}'")
      end

      data = tool_class.new(user: @user, token: @token).call(args)
      {
        isError: false,
        content: [ { type: "text", text: JSON.generate(data) } ],
        structuredContent: data
      }
    end

    def token_has_scope?(scope)
      return false unless @token

      @token.includes_scope?(scope)
    end

    def error_payload(err)
      out = { error_code: err.code, message: err.message }
      out[:details] = err.details if err.details
      out
    end

    def jsonrpc_error(id, code, message)
      {
        jsonrpc: "2.0",
        id: id,
        error: { code: code, message: message }
      }
    end
  end
end
