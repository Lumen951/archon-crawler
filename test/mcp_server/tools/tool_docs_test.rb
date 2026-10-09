require "test_helper"

# Every MCP tool has to land in three places: the tool class, the canonical
# reference (docs/mcp.md) and the /mcp guide page users actually read. Nothing
# linked them, so a tool added or renamed in the registry went unnoticed until
# someone went looking for it in the docs — which is how search_articles and
# the two event-research tools drifted out, and how list_articles came to
# document neither keyword nor fields.
#
# These tests key off McpController::TOOLS so the registry stays the single
# source of truth: register a tool and it fails until the docs describe it.
module Tools
  class ToolDocsTest < ActiveSupport::TestCase
    DOCS = Rails.root.join("docs/mcp.md")
    GUIDE = Rails.root.join("app/views/mcp_guide/show.html.erb")

    REGISTERED = McpController::TOOLS.map(&:tool_name).freeze

    test "every registered tool is documented in docs/mcp.md" do
      assert_empty REGISTERED - documented_tools,
                   "docs/mcp.md has no `### <tool>` section for these tools"
    end

    test "docs/mcp.md documents no tool that is not registered" do
      assert_empty documented_tools - REGISTERED,
                   "docs/mcp.md documents tools that McpController::TOOLS no longer registers"
    end

    test "every registered tool appears on the MCP guide page" do
      guide = GUIDE.read

      REGISTERED.each do |name|
        assert_includes guide, %(name: "#{name}"),
                        "app/views/mcp_guide/show.html.erb does not list #{name}"
      end
    end

    # A tool's input_schema is the contract; its doc section has to describe
    # every parameter in it.
    REGISTERED.each do |name|
      test "#{name} documents all of its parameters" do
        section = tool_sections[name]

        assert section, "docs/mcp.md has no `### #{name}` section"

        missing = declared_params(name).reject { |param| section.include?("`#{param}`") }

        assert_empty missing,
                     "docs/mcp.md does not describe #{missing.join(', ')} for #{name}"
      end
    end

    private

    # Top-level parameter names from the tool class — the source of truth.
    def declared_params(name)
      tool = McpController::TOOLS.find { |t| t.tool_name == name }
      (tool.input_schema.to_h[:properties] || {}).keys.map(&:to_s)
    end

    # The `### \`tool_name\`` sections of the "可用 Tools" chapter, keyed by
    # tool name. Split within that chapter only: the rest of the file has its
    # own `###` headings for connection methods and usage scenarios.
    def tool_sections
      @tool_sections ||= begin
        chapter = DOCS.read[/^## 可用 Tools\n(.*?)^## /m, 1]

        assert chapter, "docs/mcp.md has no '可用 Tools' chapter"

        chapter.split(/^### /).drop(1).each_with_object({}) do |chunk, sections|
          name = chunk[/\A`([a-z_]+)`/, 1]

          assert name, "docs/mcp.md has a `###` heading that does not name a tool: #{chunk.lines.first.to_s.strip}"

          sections[name] = chunk
        end
      end
    end

    def documented_tools
      tool_sections.keys
    end
  end
end
