/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Features:
 * - Message history display
 * - Message input
 * - Real-time streaming (via channel events)
 * - Loading states
 */

import { useEffect, useRef, useState } from "react";
import { useParams, useNavigate } from "react-router";
import { useStore } from "../store";

/**
 * Chat Page component
 */
export function ChatPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const messagesEndRef = useRef(null);
  const [inputValue, setInputValue] = useState("");
  const [isJoining, setIsJoining] = useState(true);
  const [error, setError] = useState(null);

  const { joinAgent, leaveAgent, sendMessage, messages, isStreaming } =
    useStore();

  // Scroll to bottom when messages change
  // biome-ignore lint/correctness/useExhaustiveDependencies: messages is the dependency we want
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Join agent channel on mount
  useEffect(() => {
    let mounted = true;

    const connect = async () => {
      try {
        setIsJoining(true);
        setError(null);
        await joinAgent(id);
      } catch (err) {
        if (mounted) {
          setError(err.message || "Failed to connect to agent");
        }
      } finally {
        if (mounted) {
          setIsJoining(false);
        }
      }
    };

    connect();

    return () => {
      mounted = false;
      leaveAgent();
    };
  }, [id, joinAgent, leaveAgent]);

  const handleSendMessage = async (e) => {
    e.preventDefault();

    if (!inputValue.trim() || isStreaming) {
      return;
    }

    const content = inputValue.trim();
    setInputValue("");

    try {
      await sendMessage(content);
    } catch (err) {
      setError(err.message || "Failed to send message");
    }
  };

  // Show loading state while joining
  if (isJoining) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="flex flex-col items-center gap-4">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600" />
          <p className="text-gray-600">Connecting to agent...</p>
        </div>
      </div>
    );
  }

  // Show error state
  if (error) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="max-w-md text-center">
          <div className="text-red-500 mb-4">
            <svg
              className="w-16 h-16 mx-auto"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-label="Error icon"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
              />
            </svg>
          </div>
          <h2 className="text-xl font-bold text-gray-900 mb-2">
            Connection Error
          </h2>
          <p className="text-gray-600 mb-4">{error}</p>
          <button
            type="button"
            onClick={() => navigate("/")}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            Go Home
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full max-w-4xl mx-auto">
      {/* Header */}
      <div className="border-b border-gray-200 pb-4 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-gray-900">{id}</h1>
            <p className="text-sm text-gray-500">
              {isStreaming ? "Typing..." : "Ready"}
            </p>
          </div>
          <div
            className={`
              w-3 h-3 rounded-full
              ${isStreaming ? "bg-green-500 animate-pulse" : "bg-gray-300"}
            `}
          />
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto space-y-4 mb-4 pr-2">
        {messages.length === 0 ? (
          <div className="text-center py-12 text-gray-400">
            <svg
              className="w-16 h-16 mx-auto mb-4 opacity-50"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-label="Chat icon"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={1.5}
                d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
              />
            </svg>
            <p className="text-lg font-medium">Start a conversation</p>
            <p className="text-sm mt-1">Send a message to begin chatting</p>
          </div>
        ) : (
          messages.map((message, index) => (
            <div
              // biome-ignore lint/suspicious/noArrayIndexKey: Messages are append-only, index is safe
              key={index}
              className={`
                flex gap-4 p-4 rounded-xl
                ${
                  message.role === "user"
                    ? "bg-blue-50 ml-12"
                    : "bg-gray-50 mr-12"
                }
              `}
            >
              {/* Avatar */}
              <div
                className={`
                  w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0
                  ${
                    message.role === "user"
                      ? "bg-blue-600 text-white"
                      : "bg-gray-600 text-white"
                  }
                `}
              >
                {message.role === "user" ? "U" : "AI"}
              </div>

              {/* Message content */}
              <div className="flex-1">
                <div className="flex items-center gap-2 mb-1">
                  <span className="font-semibold text-sm text-gray-700">
                    {message.role === "user" ? "You" : id}
                  </span>
                </div>
                <p className="text-gray-800 whitespace-pre-wrap">
                  {message.content}
                </p>
              </div>
            </div>
          ))
        )}

        {/* Streaming indicator */}
        {isStreaming && (
          <div className="flex gap-4 p-4 rounded-xl bg-gray-50 mr-12">
            <div className="w-8 h-8 rounded-full bg-gray-600 text-white flex items-center justify-center flex-shrink-0">
              AI
            </div>
            <div className="flex-1">
              <div className="flex items-center gap-2 mb-1">
                <span className="font-semibold text-sm text-gray-700">
                  {id}
                </span>
              </div>
              <div className="flex items-center gap-1">
                <span
                  className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                  style={{ animationDelay: "0ms" }}
                />
                <span
                  className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                  style={{ animationDelay: "150ms" }}
                />
                <span
                  className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                  style={{ animationDelay: "300ms" }}
                />
              </div>
            </div>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input area */}
      <form
        onSubmit={handleSendMessage}
        className="border-t border-gray-200 pt-4"
      >
        <div className="flex gap-2">
          <input
            type="text"
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            placeholder="Type a message..."
            disabled={isStreaming}
            className="
              flex-1 px-4 py-3 border border-gray-300 rounded-lg
              focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none
              disabled:bg-gray-100 disabled:cursor-not-allowed
            "
          />
          <button
            type="submit"
            disabled={!inputValue.trim() || isStreaming}
            className={`
              px-6 py-3 rounded-lg font-semibold text-white
              transition-all duration-200
              ${
                !inputValue.trim() || isStreaming
                  ? "bg-gray-400 cursor-not-allowed"
                  : "bg-blue-600 hover:bg-blue-700 active:bg-blue-800"
              }
            `}
          >
            Send
          </button>
        </div>
      </form>
    </div>
  );
}

export default ChatPage;
