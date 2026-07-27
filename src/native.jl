# native.jl -- WebNative: True HTML/DOM projection for ManyUI

using ManyUI
import HTTP
import JSON3

"""
Convert a ManyUI Widget tree into an HTML string.
"""
function to_html(w::ManyUI.Widget)
    node = ManyUI.node(w)
    id_str = " id=\"$(node.id)\""
    
    # Classes
    classes = [String(c) for c in node.classes]
    push!(classes, "manyui-" * lowercase(String(node.type_name)))
    class_str = " class=\"$(join(classes, " "))\""
    
    # Styling (very basic mapping for now)
    style_str = ""
    # In a real implementation, we'd map node.box and node.computed_style to CSS here.
    
    tag = "div"
    inner = ""
    
    if w isa ManyUI.Label
        tag = "span"
        inner = w.text[]
    elseif w isa ManyUI.Button
        tag = "button"
        # We inject a JS function call for click events
        id_str = " id=\"$(node.id)\" onclick=\"dispatch_event('$(node.id)', 'click')\""
        inner = w.label[]
    else
        # Generic container
        for child in node.children
            inner *= to_html(child)
        end
    end
    
    return "<$tag$id_str$class_str$style_str>$inner</$tag>"
end

"""
Generate the full HTML document for a root widget.
"""
function generate_document(root::ManyUI.Widget, title::String="ManyUI WebNative")
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>$title</title>
        <style>
            body {
                font-family: system-ui, -apple-system, sans-serif;
                background-color: #1e1e2e;
                color: #cdd6f4;
                margin: 0;
                padding: 2rem;
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 100vh;
            }
            .manyui-container {
                background: #313244;
                padding: 2rem;
                border-radius: 12px;
                box-shadow: 0 10px 30px rgba(0,0,0,0.5);
                display: flex;
                flex-direction: column;
                gap: 1rem;
                align-items: center;
            }
            .manyui-label {
                font-size: 1.2rem;
                font-weight: 500;
            }
            .manyui-button {
                background: #89b4fa;
                color: #11111b;
                border: none;
                padding: 0.75rem 1.5rem;
                font-size: 1rem;
                font-weight: 600;
                border-radius: 8px;
                cursor: pointer;
                transition: transform 0.1s, background 0.2s;
            }
            .manyui-button:hover {
                background: #b4befe;
                transform: translateY(-2px);
            }
            .manyui-button:active {
                transform: translateY(0);
            }
            .manyui-log_panel {
                width: 100%;
                background: #181825;
                border: 1px solid #45475a;
                border-radius: 8px;
                padding: 1rem;
                margin-top: 1rem;
                font-family: 'Fira Code', 'Courier New', Courier, monospace;
                font-size: 0.9rem;
                color: #a6adc8;
                align-items: flex-start;
                gap: 0.25rem;
                max-height: 200px;
                overflow-y: auto;
            }
            .manyui-log_panel .manyui-label:first-child {
                color: #fab387;
                font-weight: bold;
                margin-bottom: 0.5rem;
                align-self: center;
            }
        </style>
        <script>
            async function dispatch_event(id, event_type) {
                try {
                    const response = await fetch('/dispatch', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ id: id, event: event_type })
                    });
                    if (response.ok) {
                        // Reload to fetch the new HTML state
                        window.location.reload();
                    }
                } catch (e) {
                    console.error('Dispatch failed:', e);
                }
            }
        </script>
    </head>
    <body>
        $(to_html(root))
    </body>
    </html>
    """
end

"""
Find a widget by ID in the tree.
"""
function find_widget(w::ManyUI.Widget, id::Symbol)
    node = ManyUI.node(w)
    if node.id === id
        return w
    end
    for child in node.children
        found = find_widget(child, id)
        if found !== nothing
            return found
        end
    end
    return nothing
end

"""
Start a simple HTTP server to serve the Native DOM.
"""
function serve_native(model, proj::ManyUI.Projection, port::Int=8080)
    last_root = Ref{Union{Nothing, ManyUI.Widget}}(nothing)
    
    server = HTTP.listen!(port) do http
        if http.message.target == "/"
            # Render the current state
            root = ManyUI.render(model, proj)
            last_root[] = root
            html = generate_document(root)
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/html")
            write(http, html)
        elseif http.message.target == "/dispatch" && http.message.method == "POST"
            # Handle incoming event
            body = read(http)
            data = JSON3.read(body)
            id = Symbol(data.id)
            
            # Find the widget in the LAST rendered tree (where the ID exists)
            if last_root[] !== nothing
                w = find_widget(last_root[], id)
                if w !== nothing && w isa ManyUI.Button
                    # Execute the button's on_press action
                    w.on_press(w)
                end
            end
            
            HTTP.setstatus(http, 200)
            write(http, "OK")
        else
            HTTP.setstatus(http, 404)
            write(http, "Not Found")
        end
    end
    println("WebNative server running on http://127.0.0.1:$port")
    return server
end

# Implement the launch hook for WebNative
function ManyUI.launch(model, proj::ManyUI.WebNative; port::Int=8080, wait::Bool=true, kwargs...)
    server = serve_native(model, proj, port)
    wait || return server
    try
        # Keep alive
        Base.wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        close(server)
    end
    return 0
end
