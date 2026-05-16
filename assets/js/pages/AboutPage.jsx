/**
 * About Page - Landing page with mascot and information.
 *
 * Features:
 * - Nest mascot image
 * - Flip image toggle button
 * - Project description
 */

import { useState } from "react";
import mascotImage from "../../images/nest-mascots.jpg";

/**
 * About Page component
 */
export function AboutPage() {
  const [isFlipped, setIsFlipped] = useState(false);

  const toggleImage = () => {
    setIsFlipped(!isFlipped);
  };

  return (
    <div className="max-w-3xl mx-auto py-12">
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-8">
        {/* Title */}
        <h1 className="text-4xl font-bold text-gray-900 text-center mb-4">
          A Nest of Agents
        </h1>
        <p className="text-xl text-gray-600 text-center mb-8">
          Welcome to Nest — where intelligent agents collaborate and thrive
        </p>

        {/* Mascot Image */}
        <div className="flex justify-center mb-6">
          <div className="relative">
            <img
              src={mascotImage}
              alt="Nest Mascots"
              className={`
                max-w-md w-full rounded-xl shadow-lg transition-transform duration-300 ease-in-out
                ${isFlipped ? "scale-x-[-1]" : "scale-x-1"}
              `}
              data-testid="mascot-image"
            />
          </div>
        </div>

        {/* Flip Button */}
        <div className="flex justify-center mb-12">
          <button
            type="button"
            onClick={toggleImage}
            className="
              inline-flex items-center gap-2 px-6 py-3
              bg-indigo-600 text-white font-semibold
              rounded-lg shadow-md
              hover:bg-indigo-700 active:bg-indigo-800
              transition-colors duration-200
              focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2
            "
            data-testid="toggle-button"
          >
            <svg
              className="w-5 h-5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-label="Flip icon"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            </svg>
            {isFlipped ? "Flip Back" : "Flip Image"}
          </button>
        </div>

        {/* Description */}
        <div className="prose prose-gray max-w-none">
          <h2 className="text-2xl font-bold text-gray-900 mb-4">
            What is Nest?
          </h2>
          <p className="text-gray-600 mb-4">
            Nest is a platform for creating and managing AI agents. Each agent
            is powered by a large language model and maintains its own
            conversation history. You can create multiple agents, each with
            different models, and chat with them in real-time.
          </p>

          <h3 className="text-xl font-semibold text-gray-900 mb-3">Features</h3>
          <ul className="space-y-2 text-gray-600 mb-6">
            <li className="flex items-start gap-2">
              <svg
                className="w-5 h-5 text-green-500 flex-shrink-0 mt-0.5"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Checkmark"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
              <span>
                <strong>Multiple Agents:</strong> Create as many agents as you
                need, each with a unique identity
              </span>
            </li>
            <li className="flex items-start gap-2">
              <svg
                className="w-5 h-5 text-green-500 flex-shrink-0 mt-0.5"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Checkmark"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
              <span>
                <strong>Real-time Chat:</strong> Stream responses in real-time
                via WebSocket
              </span>
            </li>
            <li className="flex items-start gap-2">
              <svg
                className="w-5 h-5 text-green-500 flex-shrink-0 mt-0.5"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Checkmark"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
              <span>
                <strong>Model Selection:</strong> Choose from multiple language
                models
              </span>
            </li>
            <li className="flex items-start gap-2">
              <svg
                className="w-5 h-5 text-green-500 flex-shrink-0 mt-0.5"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Checkmark"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
              <span>
                <strong>Persistent Sessions:</strong> Agents run until you
                delete them
              </span>
            </li>
          </ul>

          <h3 className="text-xl font-semibold text-gray-900 mb-3">
            Getting Started
          </h3>
          <p className="text-gray-600 mb-4">
            Click "New Agent" in the sidebar to create your first agent, select
            a model, and start chatting!
          </p>
        </div>

        {/* Footer */}
        <div className="mt-12 pt-8 border-t border-gray-200 text-center">
          <p className="text-sm text-gray-400">
            Built with Phoenix, React, and LangChain
          </p>
        </div>
      </div>
    </div>
  );
}

export default AboutPage;
