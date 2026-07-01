(() => {
    "use strict";

    const SYSTEM_PROMPT = {
        role: "system",
        content:
            "You are a helpful assistant running on a local LLM gateway (LiteLLM + llama.cpp). Be concise, accurate, and friendly.",
    };

    const chatEl = document.getElementById("chat");
    const formEl = document.getElementById("chat-form");
    const inputEl = document.getElementById("message-input");
    const sendBtn = document.getElementById("send-btn");
    const newChatBtn = document.getElementById("new-chat");
    const themeToggle = document.getElementById("theme-toggle");
    const modelBadge = document.getElementById("model-badge");
    const disclaimerEl = document.getElementById("disclaimer");
    const toastContainer = document.getElementById("toast-container");

    let messages = [];
    let isStreaming = false;

    marked.setOptions({
        breaks: true,
        gfm: true,
    });

    function getTheme() {
        return localStorage.getItem("chat-theme") || "dark";
    }

    function setTheme(theme) {
        document.documentElement.setAttribute("data-theme", theme);
        localStorage.setItem("chat-theme", theme);
    }

    function showToast(message, type = "error") {
        const toast = document.createElement("div");
        toast.className = `toast toast--${type}`;
        toast.textContent = message;
        toastContainer.appendChild(toast);
        setTimeout(() => toast.remove(), 5000);
    }

    function renderMarkdown(text) {
        const raw = marked.parse(text || "");
        return DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } });
    }

    function scrollToBottom() {
        chatEl.scrollTop = chatEl.scrollHeight;
    }

    function renderEmptyState() {
        chatEl.innerHTML = `
      <div class="chat__empty">
        <h2>Try the demo</h2>
        <p>Ask anything — responses stream from Llama&nbsp;3.2&nbsp;1B via the LiteLLM gateway on the edge cluster.</p>
      </div>
    `;
    }

    function createMessageElement(role, content = "", options = {}) {
        const { typing = false } = options;
        const wrapper = document.createElement("article");
        wrapper.className = `message message--${role}${typing ? " message--typing" : ""}`;
        wrapper.dataset.role = role;

        const avatar = document.createElement("div");
        avatar.className = "message__avatar";
        avatar.textContent = role === "user" ? "You" : "AI";

        const bubble = document.createElement("div");
        bubble.className = "message__bubble";

        const roleLabel = document.createElement("span");
        roleLabel.className = "message__role";
        roleLabel.textContent = role === "user" ? "You" : "Assistant";

        const contentEl = document.createElement("div");
        contentEl.className = "message__content";
        if (content) {
            contentEl.innerHTML =
                role === "assistant"
                    ? renderMarkdown(content)
                    : escapeHtml(content);
        }

        bubble.append(roleLabel, contentEl);
        wrapper.append(avatar, bubble);
        return { wrapper, contentEl };
    }

    function escapeHtml(text) {
        const div = document.createElement("div");
        div.textContent = text;
        return div.innerHTML.replace(/\n/g, "<br>");
    }

    function appendMessage(role, content) {
        const empty = chatEl.querySelector(".chat__empty");
        if (empty) {
            empty.remove();
        }

        const { wrapper } = createMessageElement(role, content);
        chatEl.appendChild(wrapper);
        scrollToBottom();
        return wrapper;
    }

    function setStreamingState(streaming) {
        isStreaming = streaming;
        inputEl.disabled = streaming;
        sendBtn.disabled = streaming;
    }

    function parseSseChunk(chunk, onToken, onError) {
        const lines = chunk.split("\n");
        for (const line of lines) {
            if (!line.startsWith("data: ")) {
                continue;
            }
            const payload = line.slice(6).trim();
            if (!payload || payload === "[DONE]") {
                continue;
            }

            let data;
            try {
                data = JSON.parse(payload);
            } catch {
                continue;
            }

            if (data.error) {
                onError(data.error);
                return;
            }

            const token = data.choices?.[0]?.delta?.content;
            if (token) {
                onToken(token);
            }
        }
    }

    async function streamChat() {
        const payloadMessages = [SYSTEM_PROMPT, ...messages];

        const response = await fetch("/api/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ messages: payloadMessages }),
        });

        if (!response.ok) {
            throw new Error(`Request failed (${response.status})`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let assistantText = "";

        const empty = chatEl.querySelector(".chat__empty");
        if (empty) {
            empty.remove();
        }

        const { wrapper, contentEl } = createMessageElement("assistant", "", {
            typing: true,
        });
        chatEl.appendChild(wrapper);

        while (true) {
            const { done, value } = await reader.read();
            if (done) {
                break;
            }

            const chunk = decoder.decode(value, { stream: true });
            parseSseChunk(
                chunk,
                (token) => {
                    assistantText += token;
                    wrapper.classList.remove("message--typing");
                    contentEl.innerHTML = renderMarkdown(assistantText);
                    scrollToBottom();
                },
                (error) => {
                    throw new Error(error);
                },
            );
        }

        wrapper.classList.remove("message--typing");
        return assistantText;
    }

    async function handleSubmit(event) {
        event.preventDefault();
        const text = inputEl.value.trim();
        if (!text || isStreaming) {
            return;
        }

        messages.push({ role: "user", content: text });
        appendMessage("user", text);
        inputEl.value = "";
        inputEl.style.height = "auto";
        setStreamingState(true);

        try {
            const reply = await streamChat();
            if (reply) {
                messages.push({ role: "assistant", content: reply });
            }
        } catch (error) {
            showToast(error.message || "Something went wrong.");
            messages.pop();
            const userMessages = chatEl.querySelectorAll(
                '.message[data-role="user"]',
            );
            userMessages[userMessages.length - 1]?.remove();
            if (!messages.length) {
                renderEmptyState();
            }
        } finally {
            setStreamingState(false);
            inputEl.focus();
        }
    }

    function resetChat() {
        if (isStreaming) {
            return;
        }
        messages = [];
        renderEmptyState();
        inputEl.focus();
    }

    function autoResizeInput() {
        inputEl.style.height = "auto";
        inputEl.style.height = `${Math.min(inputEl.scrollHeight, 160)}px`;
    }

    async function loadConfig() {
        try {
            const response = await fetch("/api/config");
            if (response.ok) {
                const data = await response.json();
                if (data.model) {
                    modelBadge.textContent = data.model;
                }
                if (data.max_context_tokens && disclaimerEl) {
                    const contextK = Math.round(data.max_context_tokens / 1024);
                    disclaimerEl.innerHTML =
                        `<strong>Demo only.</strong> Llama&nbsp;3.2&nbsp;1B on edge homelab hardware — ` +
                        `${contextK}K context, limited RAM/CPU. Small models can be inaccurate; not for production use.`;
                }
            }
        } catch {
            // Non-fatal — default disclaimer text is fine.
        }
    }

    themeToggle.addEventListener("click", () => {
        setTheme(getTheme() === "dark" ? "light" : "dark");
    });

    newChatBtn.addEventListener("click", resetChat);
    formEl.addEventListener("submit", handleSubmit);

    inputEl.addEventListener("input", autoResizeInput);
    inputEl.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            formEl.requestSubmit();
        }
    });

    setTheme(getTheme());
    renderEmptyState();
    loadConfig();
    inputEl.focus();
})();
