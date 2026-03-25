import { useState, useEffect } from 'react'
import { Routes, Route, Navigate } from 'react-router-dom'
import { supabase } from './lib/supabase'
import Layout from './components/Layout'
import LoginPage from './pages/LoginPage'
import DashboardPage from './pages/DashboardPage'
import PredictionsPage from './pages/PredictionsPage'
import ModelsPage from './pages/ModelsPage'

export default function App() {
  const [session, setSession] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      setLoading(false)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_event, session) => setSession(session)
    )

    return () => subscription.unsubscribe()
  }, [])

  if (loading) return null

  if (!session) return <LoginPage />

  return (
    <Layout onSignOut={() => supabase.auth.signOut()}>
      <Routes>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/predictions" element={<PredictionsPage />} />
        <Route path="/models" element={<ModelsPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  )
}
