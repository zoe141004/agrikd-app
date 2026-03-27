import { useState } from 'react'
import { supabase } from '../lib/supabase'

export default function LoginPage() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleLogin = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setError(error.message)
    setLoading(false)
  }

  return (
    <div className="login-page">
      <div className="login-left">
        <div className="login-brand">
          <div className="login-brand-icon">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M12 2a10 10 0 0110 10c0 4-2.5 8-6 9.5M12 2a10 10 0 00-10 10c0 4 2.5 8 6 9.5M12 2v20M6.5 7C8 9 10 11 12 12M17.5 7C16 9 14 11 12 12"/>
            </svg>
          </div>
          <span className="login-brand-name">AgriKD Admin</span>
        </div>
        <div className="login-headline">
          Precision Agronomy<br />Management Console
        </div>
        <p className="login-desc">
          Monitor leaf disease predictions, manage ML models, track data pipelines, and oversee user activity — all in one place.
        </p>
      </div>

      <div className="login-right">
        <form className="login-box" onSubmit={handleLogin}>
          <h2>Welcome back</h2>
          <p>Sign in to access the admin dashboard</p>
          {error && <p className="error">{error}</p>}
          <div className="form-group">
            <label className="form-label">Email address</label>
            <input
              className="form-input"
              type="email"
              placeholder="admin@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </div>
          <div className="form-group">
            <label className="form-label">Password</label>
            <input
              className="form-input"
              type="password"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          <button type="submit" className="btn btn-primary" disabled={loading} style={{ width: '100%', justifyContent: 'center', padding: '10px' }}>
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
          <p className="text-muted mt-2" style={{ textAlign: 'center' }}>Admin access only</p>
        </form>
      </div>
    </div>
  )
}
