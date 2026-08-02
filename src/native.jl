# native.jl -- WebNative: True HTML/DOM projection for ManyUI

using ManyUI
import HTTP
import JSON3

"True when `w` exposes a widget-wide boolean `disabled` reactive."
function _is_disabled(w::ManyUI.Widget)::Bool
    hasproperty(w, :disabled) || return false
    value = getproperty(w, :disabled)[]
    return value isa Bool && value
end

"""
Convert a ManyUI Widget tree into an HTML string.
"""
function to_html(w::ManyUI.Widget)
    node = ManyUI.node(w)
    id_str = " id=\"$(node.id)\""

    # Classes
    classes = [String(c) for c in node.classes]
    push!(classes, "manyui-" * lowercase(String(node.type_name)))
    if _is_disabled(w)
        push!(classes, "manyui-disabled")
    end
    class_str = " class=\"$(join(classes, " "))\""

    # Translate ManyUI BoxStyle to CSS Flexbox rules
    css_props = String[]
    box = node.box

    if box.display == ManyUI.Display.NONE
        push!(css_props, "display: none")
    elseif box.display == ManyUI.Display.FLEX || w isa ManyUI.LayoutBox || w isa ManyUI.WidgetNode
        push!(css_props, "display: flex")

        dir_str = box.direction == ManyUI.Direction.ROW ? "row" :
                  box.direction == ManyUI.Direction.COLUMN ? "column" :
                  box.direction == ManyUI.Direction.ROW_REVERSE ? "row-reverse" : "column-reverse"
        push!(css_props, "flex-direction: $dir_str")

        just_str = box.justify == ManyUI.Justify.START ? "flex-start" :
                   box.justify == ManyUI.Justify.CENTER ? "center" :
                   box.justify == ManyUI.Justify.END ? "flex-end" :
                   box.justify == ManyUI.Justify.SPACE_BETWEEN ? "space-between" :
                   box.justify == ManyUI.Justify.SPACE_AROUND ? "space-around" : "space-evenly"
        push!(css_props, "justify-content: $just_str")

        align_str = box.align == ManyUI.Align.START ? "flex-start" :
                    box.align == ManyUI.Align.CENTER ? "center" :
                    box.align == ManyUI.Align.END ? "flex-end" : "stretch"
        push!(css_props, "align-items: $align_str")

        if box.gap > 0
            push!(css_props, "gap: $(box.gap * 0.5)rem")
        end
    end

    if box.grow > 0
        push!(css_props, "flex-grow: $(box.grow)")
    end

    if box.width.kind == ManyUI.Dimension.PERCENT
        push!(css_props, "width: $(box.width.value)%")
    elseif box.width.kind == ManyUI.Dimension.CELLS
        push!(css_props, "width: $(box.width.value)ch")
    end

    if box.height.kind == ManyUI.Dimension.PERCENT
        push!(css_props, "height: $(box.height.value)%")
    elseif box.height.kind == ManyUI.Dimension.CELLS
        push!(css_props, "height: $(box.height.value * 1.5)em")
    end

    # Border
    if box.border.kind != ManyUI.BorderKind.NONE && box.border.kind != ManyUI.BorderKind.BLANK
        border_style = box.border.kind == ManyUI.BorderKind.DASHED ? "dashed" : "solid"
        border_width = box.border.kind == ManyUI.BorderKind.THICK ? "2px" : "1px"
        push!(css_props, "border: $border_width $border_style rgba(255, 255, 255, 0.2)")
        push!(css_props, "border-radius: 8px")
        # Ensure padding inside borders
        push!(css_props, "padding: 1rem")
    end

    style_str = isempty(css_props) ? "" : " style=\"$(join(css_props, "; "))\""

    tag = "div"
    inner = ""

    if w isa ManyUI.Label
        tag = "span"
        inner = w.text[]
    elseif w isa ManyUI.Button
        tag = "button"
        disabled_str = _is_disabled(w) ? " disabled" : ""
        id_str = " id=\"$(node.id)\" onclick=\"dispatch_event('$(node.id)', 'click')\"$disabled_str"
        inner = w.label[]
    elseif w isa ManyUI.TextInput
        tag = "input"
        type_str = (hasproperty(w, :is_password) && w.is_password) ? "password" : "text"
        disabled_str = _is_disabled(w) ? " disabled" : ""
        id_str = """ id="$(node.id)" type="$type_str" placeholder="$(w.placeholder)" value="$(w.text[])" oninput="dispatch_event('$(node.id)', 'input', this.value)" onkeydown="if (event.key === 'Enter') dispatch_event('$(node.id)', 'submit', this.value)"$disabled_str"""
        inner = ""
    elseif w isa ManyUI.ProgressBar
        tag = "div"
        val_pct = round(w.progress[] * 100, digits=1)
        inner = """<div class="manyui-progressbar-fill" style="width: $val_pct%"></div>"""
    elseif w isa ManyUI.Checkbox
        tag = "label"
        # Style as a custom checkbox wrapper
        push!(classes, "manyui-checkbox-wrapper")
        class_str = " class=\"$(join(classes, " "))\""
        checked_str = ManyUI.is_checked(w) ? "checked" : ""
        disabled_str = _is_disabled(w) ? "disabled" : ""
        inner = """
            <input type="checkbox" $checked_str $disabled_str onchange="dispatch_event('$(node.id)', 'change', this.checked)">
            <span class="manyui-checkbox-custom"></span>
            <span class="manyui-checkbox-label">$(w.label[])</span>
        """
    elseif w isa ManyUI.Scrollpane
        # Ensure scrollpane has overflow
        push!(css_props, "overflow: auto")
        style_str = isempty(css_props) ? "" : " style=\"$(join(css_props, "; "))\""
        for child in node.children
            inner *= to_html(child)
        end
    elseif w isa ManyUI.TextArea
        tag = "textarea"
        disabled_str = _is_disabled(w) ? "disabled" : ""
        id_str = """ id="$(node.id)" oninput="dispatch_event('$(node.id)', 'input', this.value)" $disabled_str"""
        inner = join(w.lines, "\n")
    elseif w isa ManyUI.List
        tag = "div"
        push!(classes, "manyui-list")
        class_str = " class=\"$(join(classes, " "))\""
        items_html = []
        for (i, item) in enumerate(w.items)
            sel_class = i == w.sel.cursor ? " manyui-list-selected" : ""
            push!(items_html, """<div class="manyui-list-item$sel_class" onclick="dispatch_event('$(node.id)', 'change', $i)" ondblclick="dispatch_event('$(node.id)', 'submit', $i)">$(w.format(item))</div>""")
        end
        inner = join(items_html, "\n")
    elseif w isa ManyUI.DataTable || w isa ManyUI.Table
        tag = "table"
        push!(classes, "manyui-datatable")
        class_str = " class=\"$(join(classes, " "))\""

        # Header
        headers = []
        for col in w.grid.cols
            push!(headers, "<th>$(col.header)</th>")
        end
        inner *= "<thead><tr>" * join(headers, "") * "</tr></thead>"

        # Body
        inner *= "<tbody>"
        if w isa ManyUI.DataTable
            for k in 1:length(w.order)
                source_i = w.order[k]
                row = w.rows[source_i]
                sel_class = source_i == w.sel.cursor ? " class=\"manyui-table-selected\"" : ""
                inner *= "<tr$sel_class onclick=\"dispatch_event('$(node.id)', 'change', $k)\" ondblclick=\"dispatch_event('$(node.id)', 'submit', $k)\">"
                for j in 1:length(w.grid.cols)
                    val = w.cell(row, j)
                    inner *= "<td>$val</td>"
                end
                inner *= "</tr>"
            end
        else
            for (source_i, row) in enumerate(w.rows)
                sel_class = source_i == w.sel.cursor ? " class=\"manyui-table-selected\"" : ""
                inner *= "<tr$sel_class onclick=\"dispatch_event('$(node.id)', 'change', $source_i)\" ondblclick=\"dispatch_event('$(node.id)', 'submit', $source_i)\">"
                for j in 1:length(w.grid.cols)
                    val = w.cell(row, j)
                    inner *= "<td>$val</td>"
                end
                inner *= "</tr>"
            end
        end
        inner *= "</tbody>"
    elseif w isa ManyUI.DropDown
        tag = "select"
        push!(classes, "manyui-dropdown")
        class_str = " class=\"$(join(classes, " "))\""
        disabled_str = _is_disabled(w) ? " disabled" : ""
        id_str = """ id="$(node.id)" onchange="dispatch_event('$(node.id)', 'change', this.value)"$disabled_str"""
        options = []
        if w.selected[] == 0
            push!(options, "<option value=\"0\" selected disabled hidden>$(w.placeholder)</option>")
        end
        lst = w.panel.list
        for (i, item) in enumerate(lst.items)
            sel = i == w.selected[] ? " selected" : ""
            push!(options, "<option value=\"$i\"$sel>$(lst.format(item))</option>")
        end
        inner = join(options, "\n")
    elseif w isa ManyUI.RadioGroup
        tag = "div"
        push!(classes, "manyui-radiogroup")
        class_str = " class=\"$(join(classes, " "))\""
        options = String[]
        disabled_options = w.disabled[]
        for (i, option) in enumerate(w.options)
            checked = i == w.selected[] ? " checked" : ""
            disabled = i in disabled_options ? " disabled" : ""
            push!(options, """<label><input type="radio" name="$(node.id)" value="$i"$checked$disabled onchange="dispatch_event('$(node.id)', 'change', $i)"><span>$option</span></label>""")
        end
        inner = join(options, "\n")
    elseif w isa ManyUI.TreeView
        tag = "div"
        push!(classes, "manyui-treeview")
        class_str = " class=\"$(join(classes, " "))\""
        rows_html = []
        rows = ManyUI._tv_flat!(w)
        for (i, row) in enumerate(rows)
            sel_class = i == w.sel.cursor ? " manyui-tree-selected" : ""
            pad = row.depth * 20
            has_children = !ManyUI.is_leaf(row.node)
            twisty = has_children ? (ManyUI.is_expanded(row.node) ? "▼ " : "▶ ") : "  "
            html = """<div class="manyui-tree-row$sel_class" style="padding-left: $(pad)px;">"""
            html *= """<span class="manyui-tree-twisty" onclick="dispatch_event('$(node.id)', 'toggle', $i); event.stopPropagation();">$twisty</span>"""
            html *= """<span class="manyui-tree-label" onclick="dispatch_event('$(node.id)', 'change', $i)" ondblclick="dispatch_event('$(node.id)', 'submit', $i)">$(w.format(row.node.value))</span>"""
            html *= "</div>"
            push!(rows_html, html)
        end
        inner = join(rows_html, "\n")
    else
        # Generic container
        for child in node.children
            inner *= to_html(child)
        end
    end

    is_disabled = _is_disabled(w)
    focus_attrs = node.focusable && !is_disabled ?
        " tabindex=\"0\" onfocus=\"dispatch_event('$(node.id)', 'focus')\" onblur=\"dispatch_event('$(node.id)', 'blur')\"" : ""
    return "<$tag$id_str$class_str$style_str$focus_attrs>$inner</$tag>"
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
        <script src="https://unpkg.com/morphdom@2.7.4/dist/morphdom-umd.min.js"></script>
        <style>
            @import url('https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&display=swap');

            body {
                font-family: 'Outfit', sans-serif;
                background: linear-gradient(135deg, #1e003b 0%, #3a0ca3 100%);
                color: #ffffff;
                margin: 0;
                padding: 2rem;
                display: flex;
                justify-content: center;
                align-items: flex-start; /* flex-start prevents cutting off top when overflowing */
                min-height: 100vh;
                overflow-x: hidden;
                overflow-y: auto;
            }

            /* Background decorative blobs */
            body::before {
                content: '';
                position: absolute;
                width: 400px;
                height: 400px;
                background: #f72585;
                border-radius: 50%;
                filter: blur(80px);
                opacity: 0.5;
                top: -100px;
                left: -100px;
                z-index: -1;
                animation: float 6s ease-in-out infinite;
            }
            body::after {
                content: '';
                position: absolute;
                width: 300px;
                height: 300px;
                background: #4cc9f0;
                border-radius: 50%;
                filter: blur(60px);
                opacity: 0.6;
                bottom: -50px;
                right: -50px;
                z-index: -1;
                animation: float 8s ease-in-out infinite reverse;
            }

            @keyframes float {
                0% { transform: translateY(0px) scale(1); }
                50% { transform: translateY(-30px) scale(1.05); }
                100% { transform: translateY(0px) scale(1); }
            }

            .manyui-container, .manyui-immediatecontainer {
                background: rgba(255, 255, 255, 0.05);
                backdrop-filter: blur(20px);
                -webkit-backdrop-filter: blur(20px);
                border: 1px solid rgba(255, 255, 255, 0.1);
                padding: 3rem;
                border-radius: 24px;
                box-shadow: 0 25px 50px rgba(0,0,0,0.3), inset 0 0 0 1px rgba(255,255,255,0.05);
                display: flex;
                flex-direction: column;
                gap: 1.5rem;
                align-items: center;
                min-width: 400px;
                animation: popup 0.5s cubic-bezier(0.175, 0.885, 0.32, 1.275);
            }

            @keyframes popup {
                0% { transform: scale(0.9); opacity: 0; }
                100% { transform: scale(1); opacity: 1; }
            }

            .manyui-label {
                font-size: 1.5rem;
                font-weight: 600;
                text-align: center;
                text-shadow: 0 2px 10px rgba(0,0,0,0.2);
            }

            .manyui-button {
                background: linear-gradient(90deg, #f72585, #b5179e);
                color: white;
                border: none;
                padding: 1rem 2rem;
                font-size: 1.1rem;
                font-weight: 600;
                font-family: 'Outfit', sans-serif;
                border-radius: 50px;
                cursor: pointer;
                box-shadow: 0 10px 20px rgba(247, 37, 133, 0.3);
                transition: all 0.3s cubic-bezier(0.25, 0.8, 0.25, 1);
            }

            .manyui-button:hover {
                transform: translateY(-3px) scale(1.05);
                box-shadow: 0 15px 25px rgba(247, 37, 133, 0.4);
            }

            .manyui-button:active {
                transform: translateY(1px) scale(0.95);
            }

            .manyui-button:disabled {
                background: rgba(255, 255, 255, 0.1);
                color: rgba(255, 255, 255, 0.3);
                box-shadow: none;
                transform: none;
                cursor: not-allowed;
            }

            .manyui-disabled {
                opacity: 0.5;
                pointer-events: none;
                cursor: not-allowed !important;
                filter: grayscale(80%);
            }

            .manyui-textinput {
                background: rgba(0, 0, 0, 0.2);
                border: 2px solid rgba(255, 255, 255, 0.1);
                color: white;
                padding: 1rem 1.5rem;
                font-size: 1.1rem;
                font-family: 'Outfit', sans-serif;
                border-radius: 12px;
                width: 100%;
                box-sizing: border-box;
                transition: all 0.3s ease;
                outline: none;
            }

            .manyui-textinput:focus {
                border-color: #4cc9f0;
                box-shadow: 0 0 15px rgba(76, 201, 240, 0.3);
                background: rgba(0, 0, 0, 0.3);
            }

            .manyui-textinput::placeholder {
                color: rgba(255, 255, 255, 0.4);
            }

            .manyui-progressbar {
                width: 100%;
                height: 12px;
                background: rgba(0, 0, 0, 0.3);
                border-radius: 6px;
                overflow: hidden;
                border: 1px solid rgba(255, 255, 255, 0.1);
                box-shadow: inset 0 2px 5px rgba(0,0,0,0.2);
            }

            .manyui-progressbar-fill {
                height: 100%;
                background: linear-gradient(90deg, #4cc9f0, #4361ee);
                border-radius: 6px;
                transition: width 0.3s ease;
                box-shadow: 0 0 10px rgba(76, 201, 240, 0.5);
            }

            .manyui-checkbox-wrapper {
                display: flex;
                align-items: center;
                gap: 0.75rem;
                cursor: pointer;
                user-select: none;
            }
            .manyui-checkbox-wrapper input {
                display: none;
            }
            .manyui-checkbox-custom {
                width: 24px;
                height: 24px;
                border: 2px solid rgba(255, 255, 255, 0.3);
                border-radius: 6px;
                display: flex;
                justify-content: center;
                align-items: center;
                transition: all 0.2s ease;
                background: rgba(0,0,0,0.2);
            }
            .manyui-checkbox-wrapper input:checked + .manyui-checkbox-custom {
                background: linear-gradient(135deg, #f72585, #b5179e);
                border-color: transparent;
                box-shadow: 0 0 10px rgba(247, 37, 133, 0.4);
            }
            .manyui-checkbox-wrapper input:checked + .manyui-checkbox-custom::after {
                content: '✓';
                color: white;
                font-weight: bold;
                font-size: 16px;
            }
            .manyui-checkbox-label {
                font-size: 1.1rem;
            }

            .manyui-textarea {
                background: rgba(0, 0, 0, 0.2);
                border: 2px solid rgba(255, 255, 255, 0.1);
                color: white;
                padding: 1rem;
                font-size: 1.1rem;
                font-family: 'Fira Code', 'Courier New', Courier, monospace;
                border-radius: 12px;
                width: 100%;
                min-height: 100px;
                box-sizing: border-box;
                transition: all 0.3s ease;
                outline: none;
                resize: vertical;
            }

            .manyui-textarea:focus {
                border-color: #f72585;
                box-shadow: 0 0 15px rgba(247, 37, 133, 0.3);
            }

            .manyui-list {
                background: rgba(0, 0, 0, 0.2);
                border-radius: 12px;
                border: 1px solid rgba(255, 255, 255, 0.1);
                overflow: hidden;
                width: 100%;
            }

            .manyui-list-item {
                padding: 1rem 1.5rem;
                cursor: pointer;
                border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                transition: background 0.2s;
            }

            .manyui-list-item:hover {
                background: rgba(255, 255, 255, 0.05);
            }

            .manyui-list-selected {
                background: rgba(76, 201, 240, 0.2) !important;
                border-left: 4px solid #4cc9f0;
                font-weight: bold;
            }

            .manyui-datatable {
                width: 100%;
                border-collapse: collapse;
                background: rgba(0, 0, 0, 0.2);
                border-radius: 12px;
                overflow: hidden;
            }

            .manyui-datatable th {
                background: rgba(255, 255, 255, 0.1);
                padding: 1rem;
                text-align: left;
                font-weight: bold;
                border-bottom: 2px solid rgba(255, 255, 255, 0.2);
            }

            .manyui-datatable td {
                padding: 1rem;
                border-bottom: 1px solid rgba(255, 255, 255, 0.05);
            }

            .manyui-datatable tr:hover td {
                background: rgba(255, 255, 255, 0.05);
                cursor: pointer;
            }

            .manyui-table-selected td {
                background: rgba(247, 37, 133, 0.2) !important;
            }

            .manyui-log_panel {
                width: 100%;
                background: rgba(0, 0, 0, 0.3);
                border: 1px solid rgba(255, 255, 255, 0.05);
                border-radius: 12px;
                padding: 1.5rem;
                margin-top: 1rem;
                font-family: 'Fira Code', 'Courier New', Courier, monospace;
                font-size: 0.95rem;
                color: #a6adc8;
                align-items: flex-start;
                gap: 0.5rem;
                max-height: 200px;
                overflow-y: auto;
                box-shadow: inset 0 5px 15px rgba(0,0,0,0.2);
            }

            /* Custom scrollbar */
            ::-webkit-scrollbar {
                width: 8px;
            }
            ::-webkit-scrollbar-track {
                background: rgba(255,255,255,0.05);
                border-radius: 4px;
            }
            ::-webkit-scrollbar-thumb {
                background: rgba(255,255,255,0.2);
                border-radius: 4px;
            }
            ::-webkit-scrollbar-thumb:hover {
                background: rgba(255,255,255,0.3);
            }
        </style>
        <script>
            // Client state
            let ws = null;
            let use_polling = false;
            let poll_interval = null;

            function update_dom(html) {
                // Preserve focus
                const active = document.activeElement;
                const active_id = active ? active.id : null;
                const active_start = active ? active.selectionStart : null;
                const active_end = active ? active.selectionEnd : null;

                if (typeof morphdom !== 'undefined') {
                    const temp = document.createElement('div');
                    temp.innerHTML = html;
                    morphdom(document.body, temp, {
                        childrenOnly: true,
                        onBeforeElUpdated: function(fromEl, toEl) {
                            if (fromEl === active && (fromEl.tagName === 'INPUT' || fromEl.tagName === 'TEXTAREA')) {
                                toEl.value = fromEl.value;
                            }
                            return true;
                        }
                    });
                } else {
                    document.body.innerHTML = html;
                }

                // Restore focus
                if (active_id) {
                    const el = document.getElementById(active_id);
                    if (el && document.activeElement !== el) {
                        el.focus();
                        if (el.setSelectionRange && active_start !== null) {
                            el.setSelectionRange(active_start, active_end);
                        }
                    }
                }
            }

            function connect() {
                const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
                const ws_url = protocol + '//' + window.location.host + '/ws';
                ws = new WebSocket(ws_url);

                ws.onopen = function() {
                    console.log("WebSocket connected.");
                    use_polling = false;
                    if (poll_interval) {
                        clearInterval(poll_interval);
                        poll_interval = null;
                    }
                };

                ws.onmessage = function(event) {
                    const data = JSON.parse(event.data);
                    if (data.type === "update") {
                        update_dom(data.html);
                    }
                };

                ws.onclose = function() {
                    console.log("WebSocket closed. Falling back to polling...");
                    ws = null;
                    start_polling();
                };

                ws.onerror = function(err) {
                    console.error("WebSocket error:", err);
                    ws.close();
                };
            }

            function start_polling() {
                use_polling = true;
                if (!poll_interval) {
                    poll_interval = setInterval(async () => {
                        try {
                            const response = await fetch('/poll');
                            if (response.ok) {
                                const data = await response.json();
                                if (data.html) {
                                    update_dom(data.html);
                                }
                            }
                        } catch (e) {
                            console.error("Poll failed", e);
                        }
                    }, 500); // 500ms polling
                }
            }

            async function dispatch_event(id, event_type, value = null) {
                const payload = { id: id, event: event_type, value: value };
                if (ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify(payload));
                } else {
                    try {
                        const response = await fetch('/dispatch', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(payload)
                        });
                        if (response.ok) {
                            const data = await response.json();
                            if (data.html) {
                                update_dom(data.html);
                            }
                        }
                    } catch (e) {
                        console.error('Dispatch failed:', e);
                    }
                }
            }

            window.onload = connect;
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
Apply one WebNative DOM event to the matching widget in `root`.

The DOM event vocabulary mirrors the Julia callback vocabulary:
`click`, `change`, `submit`, `focus`, and `blur`.
"""
function process_native_event!(root::ManyUI.Widget, data)::Bool
    w = find_widget(root, Symbol(data.id))
    w === nothing && return false
    event_name = String(data.event)

    if event_name == "focus"
        ManyUI.on_focus!(w)
        return true
    elseif event_name == "blur"
        ManyUI.on_blur!(w)
        return true
    end

    _is_disabled(w) && return false
    value = hasproperty(data, :value) ? data.value : nothing

    if w isa ManyUI.Button
        event_name == "click" || return false
        w.on_click(w)
    elseif w isa ManyUI.TextInput
        if event_name == "input" || event_name == "submit"
            next_text = value === nothing ? "" : string(value)
            if w.text[] != next_text
                w.text[] = next_text
                ManyUI.move_to!(w, typemax(Int))
                w.on_change(w)
            end
            event_name == "submit" && w.on_submit(w)
        else
            return false
        end
    elseif w isa ManyUI.TextArea
        event_name == "input" || return false
        next_text = value === nothing ? "" : string(value)
        ManyUI.text(w) == next_text || ManyUI.set_text!(w, next_text)
    elseif w isa ManyUI.Checkbox
        event_name == "change" || return false
        target = value === true ? ManyUI.CheckState.CHECKED :
                 ManyUI.CheckState.UNCHECKED
        ManyUI.set_state!(w, target)
    elseif w isa ManyUI.List || w isa ManyUI.DataTable || w isa ManyUI.Table
        value === nothing && return false
        event_name in ("change", "submit") || return false
        ManyUI.set_cursor!(w, Int(value))
        event_name == "submit" && w.on_submit(w)
    elseif w isa ManyUI.DropDown
        event_name == "change" || return false
        value === nothing && return false
        ManyUI._dd_select!(w, parse(Int, string(value)))
    elseif w isa ManyUI.RadioGroup
        event_name == "change" || return false
        value === nothing && return false
        ManyUI.choose!(w, Int(value))
    elseif w isa ManyUI.TreeView
        value === nothing && return false
        idx = Int(value)
        if event_name == "toggle"
            ManyUI.toggle_node!(w, idx)
        elseif event_name == "change" || event_name == "submit"
            ManyUI.set_cursor!(w, idx)
            event_name == "submit" && w.on_submit(w)
        else
            return false
        end
    else
        return false
    end
    return true
end

struct WebNativeSessionApp
    root::Any
    back::Any # Mock back buffer
end

struct WebNativeSession
    app::WebNativeSessionApp
end

struct WebNativeServer
    http_server::HTTP.Server
    sessions::Dict{String, WebNativeSession}
    broadcast_update::Function
end

Base.wait(server::WebNativeServer) = Base.wait(server.http_server)
Base.close(server::WebNativeServer) = Base.close(server.http_server)
ManyUITUI.stop!(server::WebNativeServer) = close(server)

# Fake back buffer for animated demos
struct MockBuffer
    size::ManyUITUI.Size
end
ManyUITUI.buffer_size(b::MockBuffer) = b.size

# trigger a re-render when a background task posts an event
ManyUI.post!(app::WebNativeSessionApp, evt) = nothing
ManyUI.post!(server::WebNativeServer, evt) = server.broadcast_update()

function serve_native(model, proj::ManyUI.Projection, port::Int=8080)
    root_instance = ManyUI.render(model, proj)
    last_root = Ref{Union{Nothing, ManyUI.Widget}}(root_instance)
    ws_connections = Set{Any}()

    function broadcast_update()
        html = to_html(last_root[])
        msg = JSON3.write(Dict("type" => "update", "html" => html))
        for ws in copy(ws_connections)
            try
                HTTP.WebSockets.send(ws, msg)
            catch
                pop!(ws_connections, ws, nothing)
            end
        end
    end

    function process_event(data)
        last_root[] === nothing || process_native_event!(last_root[], data)
        broadcast_update()
    end

    server = HTTP.listen!(port) do http
        if http.message.target == "/ws" && HTTP.WebSockets.isupgrade(http.message)
            HTTP.WebSockets.upgrade(http) do ws
                push!(ws_connections, ws)
                try
                    for msg in ws
                        if msg isa String
                            payload = JSON3.read(msg)
                            process_event(payload)
                        elseif msg isa Vector{UInt8}
                            str = String(msg)
                            payload = JSON3.read(str)
                            process_event(payload)
                        end
                    end
                finally
                    pop!(ws_connections, ws, nothing)
                end
            end
            return
        elseif http.message.target == "/"
            # Render the initial state
            html = generate_document(last_root[])
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/html")
            write(http, html)
        elseif http.message.target == "/poll" && http.message.method == "GET"
            # Fallback polling
            html = to_html(last_root[])
            msg = JSON3.write(Dict("html" => html))
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            write(http, msg)
        elseif http.message.target == "/dispatch" && http.message.method == "POST"
            # Handle incoming event from fetch
            body = read(http)
            payload = JSON3.read(body)
            process_event(payload)

            root = last_root[]
            html = root !== nothing ? to_html(root) : ""
            msg = JSON3.write(Dict("html" => html))
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            write(http, msg)
        else
            HTTP.setstatus(http, 404)
            write(http, "Not Found")
        end
    end
    println("WebNative server running on http://127.0.0.1:$port")

    # Initialize one global session for animated demos
    sessions = Dict("default" => WebNativeSession(WebNativeSessionApp(last_root[], MockBuffer(ManyUITUI.Size(80, 24)))))

    return WebNativeServer(server, sessions, broadcast_update)
end

# Implement the launch hook for WebNative
function ManyUITUI.launch(model, proj::ManyUI.WebNative; port::Int=8080, wait::Bool=true, kwargs...)
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
