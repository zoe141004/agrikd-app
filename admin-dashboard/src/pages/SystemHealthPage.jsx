import { useState, useEffect, useRef } from 'react'
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'
import { supabase } from '../lib/supabase'
import CustomTooltip from '../components/CustomTooltip'

export default function SystemHealthPage() {
  const [checks, setChecks] = useState({})
  const [dbStats, setDbStats] = useState({ predictions: 0, models: 0, uptime: null })
  const [latencyData, setLatencyData] = useState([])
  const [loading, setLoading] = useState(true)
  const [lastChecked, setLastChecked] = useState(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    runHealthChecks()
    return () => { mountedRef.current = false }
  }, [])

  // Auto-refresh every 120 seconds
  useEffect(() => {
    const id = setInterval(runHealthChecks, 120000)
    return () => clearInterval(id)
  }, [])

  const runHealthChecks = async () => {
    setLoading(true)
    const results = {}

    // DB check
    const t0 = Date.now()
    try {
      const { count, error } = await supabase.from('predictions').select('*', { count: 'exact', head: true })
      const latency = Date.now() - t0
      results.database = { ok: !error, label: error ? 'Error' : 'Connected', latency }

      const { count: models } = await supabase.from('model_registry').select('*', { count: 'exact', head: true })
      const { data: earliest } = await supabase.from('predictions').select('created_at').order('created_at', { ascending: true }).limit(1)
      const uptime = earliest?.[0]?.created_at ? Math.floor((Date.now() - new Date(earliest[0].created_at).getTime()) / 86400000) : null
      setDbStats({ predictions: count || 0, models: models || 0, uptime })
    } catch (e) {
      results.database = { ok: false, label: 'Unreachable', latency: null }
    }

    // Auth check
    try {
      const { data: { session } } = await supabase.auth.getSession()
      results.auth = { ok: !!session, label: session ? 'Active' : 'No session' }
    } catch { results.auth = { ok: false, label: 'Error' } }

    // Storage check
    try {
      const { data, error } = await supabase.storage.listBuckets()
      results.storage = { ok: !error, label: error ? 'Error' : `${(data || []).length} buckets` }
    } catch { results.storage = { ok: false, label: 'Unavailable' } }

    // Real latency measurements (3 sequential pings)
    const latencyResults = []
    for (let i = 0; i < 3; i++) {
      const t1 = Date.now()
      await supabase.from('predictions').select('*', { count: 'exact', head: true })
      latencyResults.push({ time: `#${i + 1}`, ms: Date.now() - t1 })
    }
    setLatencyData(latencyResults)
    if (!mountedRef.current) return
    setChecks(results)
    setLastChecked(new Date())
    setLoading(false)
  }

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Running health checks...</span></div>

  const statusCards = [
    { key: 'database', label: 'Database', desc: 'Supabase PostgreSQL' },
    { key: 'auth', label: 'Authentication', desc: 'Supabase Auth' },
    { key: 'storage', label: 'Storage', desc: 'Supabase Storage' },
  ]

  return (
    <>
      <div className="page-header flex justify-between items-center">
        <div>
          <h1 className="page-title">System Health</h1>
          <p className="page-subtitle">Infrastructure status, database metrics, and error monitoring</p>
        </div>
        <button className="btn btn-primary" onClick={runHealthChecks}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/></svg>
          Re-check
        </button>
        {lastChecked && <span style={{ fontSize: 11, color: '#94a3b8' }}>Last: {lastChecked.toLocaleTimeString()}</span>}
      </div>

      <div className="stats-grid">
        {statusCards.map(s => {
          const c = checks[s.key] || {}
          return (
            <div key={s.key} className="stat-card" style={{ padding: '16px 20px' }}>
              <div className="stat-card-accent" style={{ background: c.ok ? '#16a34a' : '#dc2626' }} />
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
                <span className={`status-dot ${c.ok ? 'green' : 'red'}`} />
                <span className="stat-label">{s.label}</span>
              </div>
              <div style={{ fontFamily: 'Manrope, sans-serif', fontSize: 18, fontWeight: 700, color: '#121c28', marginBottom: 2 }}>{c.label || '—'}</div>
              <div style={{ fontSize: 12, color: '#94a3b8' }}>{s.desc}{c.latency ? ` · ${c.latency}ms` : ''}</div>
            </div>
          )
        })}
        <div className="stat-card" style={{ padding: '16px 20px' }}>
          <div className="stat-card-accent" style={{ background: '#7c3aed' }} />
          <div className="stat-label">System Uptime</div>
          <div style={{ fontFamily: 'Manrope, sans-serif', fontSize: 18, fontWeight: 700, color: '#121c28', marginTop: 6 }}>
            {dbStats.uptime !== null ? `${dbStats.uptime} days` : '—'}
          </div>
          <div style={{ fontSize: 12, color: '#94a3b8' }}>Since first prediction record</div>
        </div>
      </div>

      <div className="charts-grid">
        <div className="card">
          <div className="card-header"><div><div className="card-label">Performance</div><div className="card-title">Live Latency Samples (ms)</div></div></div>
          <ResponsiveContainer width="100%" height={180}>
            <LineChart data={latencyData} margin={{ top: 0, right: 0, left: -20, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="rgba(0,0,0,0.05)" />
              <XAxis dataKey="time" tick={{ fontSize: 10, fill: '#94a3b8' }} axisLine={false} tickLine={false} />
              <YAxis tick={{ fontSize: 10, fill: '#94a3b8' }} axisLine={false} tickLine={false} unit="ms" />
              <Tooltip />
              <Line type="monotone" dataKey="ms" name="Latency" stroke="#0284c7" strokeWidth={2} dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>

        <div className="card">
          <div className="card-header"><div><div className="card-label">Database</div><div className="card-title">Storage Overview</div></div></div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            {[
              { label: 'Predictions table', value: dbStats.predictions.toLocaleString(), icon: '📊' },
              { label: 'Model registry', value: dbStats.models.toLocaleString(), icon: '🧠' },
              { label: 'Auth users', value: 'Via Supabase', icon: '🔐' },
            ].map(item => (
              <div key={item.label} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 12px', background: '#f8fafb', borderRadius: 8 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: '#3d4f62' }}>
                  <span>{item.icon}</span>{item.label}
                </div>
                <span style={{ fontFamily: 'Manrope, sans-serif', fontWeight: 700, color: '#121c28', fontSize: 14 }}>{item.value}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </>
  )
}
