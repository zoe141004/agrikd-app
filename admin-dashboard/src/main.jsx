import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import * as Sentry from '@sentry/react'
import App from './App'
import './index.css'

const sentryDsn = import.meta.env.VITE_SENTRY_DSN
if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    environment: import.meta.env.MODE,
    tracesSampleRate: 0.2,
  })
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <Sentry.ErrorBoundary fallback={<p>Something went wrong. Please reload.</p>}>
        <App />
      </Sentry.ErrorBoundary>
    </BrowserRouter>
  </React.StrictMode>,
)
