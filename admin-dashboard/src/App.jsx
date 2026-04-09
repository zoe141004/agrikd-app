import { useState, useEffect } from 'react'
import { Routes, Route, Navigate } from 'react-router-dom'
import { supabase } from './lib/supabase'
import Layout from './components/Layout'
import ErrorBoundary from './components/ErrorBoundary'
import LoginPage from './pages/LoginPage'
import DashboardPage from './pages/DashboardPage'
import PredictionsPage from './pages/PredictionsPage'
import ModelsPage from './pages/ModelsPage'
import UsersPage from './pages/UsersPage'
import DataManagementPage from './pages/DataManagementPage'
import ReleasesPage from './pages/ReleasesPage'
import SystemHealthPage from './pages/SystemHealthPage'
import SettingsPage from './pages/SettingsPage'
import ModelReportsPage from './pages/ModelReportsPage'
import DevicesPage from './pages/DevicesPage'

export default function App() {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)
  const [accessDenied, setAccessDenied] = useState(false)
  const [authError, setAuthError] = useState(null)

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      if (!session) setLoading(false)
    }).catch((err) => {
      setAuthError(err?.message || 'Failed to load session')
      setLoading(false)
    })
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session)
      if (!session) {
        setProfile(null)
        setAccessDenied(false)
        setLoading(false)
      }
    })
    return () => subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) return
    supabase
      .from('profiles')
      .select('role, is_active, email')
      .eq('id', session.user.id)
      .single()
      .then(({ data, error }) => {
        if (error || !data || data.role !== 'admin') {
          setAccessDenied(true)
          setProfile(data || null)
        } else {
          setProfile(data)
          setAccessDenied(false)
        }
        setLoading(false)
      }).catch(() => {
        setLoading(false)
      })
  }, [session])

  if (loading) return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '100vh', background: '#f0f4f8' }}>
      <div style={{ textAlign: 'center' }}>
        <div className="spinner" style={{ margin: '0 auto 12px' }} />
        <div style={{ fontSize: 13, color: '#64748b' }}>Loading…</div>
      </div>
    </div>
  )
  if (!session) return (
    <>
      {authError && (
        <div style={{ position: 'fixed', top: 16, left: '50%', transform: 'translateX(-50%)', zIndex: 9999,
          background: '#fee2e2', color: '#dc2626', padding: '10px 20px', borderRadius: 8,
          fontSize: 13, fontWeight: 500, boxShadow: '0 2px 8px rgba(0,0,0,0.1)' }}>
          {authError}
        </div>
      )}
      <LoginPage />
    </>
  )

  if (accessDenied) return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '100vh', background: '#f0f4f8' }}>
      <div style={{ textAlign: 'center', maxWidth: 420, padding: 40 }}>
        <div style={{ width: 56, height: 56, borderRadius: 16, background: '#fee2e2', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 16px' }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="#dc2626" strokeWidth="1.5" style={{ width: 28, height: 28 }}>
            <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
          </svg>
        </div>
        <h2 style={{ fontFamily: 'Manrope, sans-serif', fontSize: 20, fontWeight: 700, color: '#121c28', marginBottom: 8 }}>Access Denied</h2>
        <p style={{ fontSize: 14, color: '#64748b', marginBottom: 24, lineHeight: 1.6 }}>
          Your account ({session.user.email}) does not have administrator privileges. Contact your system admin to request access.
        </p>
        <button className="btn btn-primary" onClick={() => supabase.auth.signOut()}>Sign Out</button>
      </div>
    </div>
  )

  return (
    <ErrorBoundary>
      <Layout session={session} profile={profile} onSignOut={() => supabase.auth.signOut()}>
        <Routes>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/predictions" element={<PredictionsPage />} />
          <Route path="/models" element={<ModelsPage />} />
          <Route path="/users" element={<UsersPage />} />
          <Route path="/devices" element={<DevicesPage />} />
          <Route path="/data" element={<DataManagementPage />} />
          <Route path="/releases" element={<ReleasesPage />} />
          <Route path="/health" element={<SystemHealthPage />} />
          <Route path="/reports" element={<ModelReportsPage />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Layout>
    </ErrorBoundary>
  )
}
