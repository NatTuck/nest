import { useState } from 'react';
import mascotImage from '../../images/nest-mascots.jpg';

/**
 * NestLanding component - A landing page for "A Nest of Agents"
 * Features a mascot image with a toggle button to flip it horizontally
 */
export function NestLanding() {
  const [isFlipped, setIsFlipped] = useState(false);

  const toggleImage = () => {
    setIsFlipped(!isFlipped);
  };

  const imageStyle = {
    transform: isFlipped ? 'scaleX(-1)' : 'scaleX(1)',
    transition: 'transform 0.3s ease-in-out',
  };

  const buttonStyle = {
    padding: '12px 24px',
    fontSize: '16px',
    fontWeight: '600',
    backgroundColor: '#4f46e5',
    color: 'white',
    border: 'none',
    borderRadius: '8px',
    cursor: 'pointer',
    transition: 'background-color 0.2s ease',
  };

  const buttonHoverStyle = {
    backgroundColor: '#4338ca',
  };

  return (
    <div style={{ 
      display: 'flex', 
      flexDirection: 'column', 
      alignItems: 'center', 
      justifyContent: 'center',
      minHeight: '100vh',
      padding: '2rem',
      textAlign: 'center',
    }}>
      <h1 style={{ 
        fontSize: '3rem', 
        fontWeight: '700', 
        marginBottom: '1rem',
        color: '#1f2937',
      }}>
        A Nest of Agents
      </h1>
      
      <p style={{ 
        fontSize: '1.25rem', 
        color: '#6b7280', 
        marginBottom: '2rem',
        maxWidth: '600px',
      }}>
        Welcome to Nest - where intelligent agents collaborate and thrive
      </p>

      <div style={{ marginBottom: '2rem' }}>
        <img 
          src={mascotImage}
          alt="Nest Mascots"
          style={imageStyle}
          data-testid="mascot-image"
        />
      </div>

      <button
        onClick={toggleImage}
        style={buttonStyle}
        onMouseEnter={(e) => {
          e.target.style.backgroundColor = buttonHoverStyle.backgroundColor;
        }}
        onMouseLeave={(e) => {
          e.target.style.backgroundColor = buttonStyle.backgroundColor;
        }}
        data-testid="toggle-button"
      >
        {isFlipped ? 'Flip Back' : 'Flip Image'}
      </button>

      <p style={{ 
        marginTop: '1rem', 
        fontSize: '0.875rem', 
        color: '#9ca3af',
      }}>
        Click the button to flip the image horizontally
      </p>
    </div>
  );
}
