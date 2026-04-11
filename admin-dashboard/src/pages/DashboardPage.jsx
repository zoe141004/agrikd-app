import { useState, useEffect, useRef } from 'react'
import {
  AreaChart, Area, BarChart, Bar, XAxis, YAxis,
  CartesianGrid, Tooltip, ResponsiveContainer, Cell
} from 'recharts'
import { supabase } from '../lib/supabase'
import { useData } from '../lib/DataContext'
import { cleanLabel } from '../lib/helpers'
import CustomTooltip from '../components/CustomTooltip'

export default function DashboardPage() {
  const { leafTypeOptions, refreshKey } = useData()
  const [stats, setStats] = useState({ total: 0, users: 0, models: 0, devices: 0 })
  const [diseaseData, setDiseaseData] = useState([])
  const [dailyData, setDailyData] = useState([])
  const [recentPreds, setRecentPreds] = useState([])
  const [leafSplit, setLeafSplit] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [leafFilter, setLeafFilter] = useState('')

  // Ref to track latest leafFilter inside interval callback (avoids stale closure)
  const leafFilterRef = useRef(leafFilter)
  useEffect(() => { leafFilterRef.current = leafFilter }, [leafFilter])

  // Primary load: re-fetch when filter changes, cancel on unmount or re-trigger
  useEffect(() => {
    const controller = new AbortController()
    loadDashboard(true, controller.signal)
    return () => controller.abort()
  }, [leafFilter, refreshKey])

  // Auto-refresh every 60s — single interval, reads latest filter via ref
  useEffect(() => {
    const id = setInterval(() => {
      const controller = new AbortController()
      loadDashboard(false, controller.signal)
    }, 60000)
    return () => clearInterval(id)
  }, [])

  const loadDashboard = async (showSpinner, signal) => {
    if (showSpinner) setLoading(true)
    setError(null)
    try {
    const currentFilter = leafFilterRef.current
    const rpcFilter = currentFilter || null
    const addFilter = (q) => currentFilter ? q.eq('leaf_type', currentFilter) : q

    const [
      rpcStatsRes,
      diseaseDistRes,
      modelsRes,
      dailyRowsRes,
      recentRes,
      devicesRes,
    ] = await Promise.allSettled([
      supabase.rpc('get_dashboard_stats', { p_leaf_type: rpcFilter }),
      supabase.rpc('get_disease_distribution', { p_leaf_type: rpcFilter }),
      supabase.from('model_registry').select('*', { count: 'exact', head: true }),
      addFilter(supabase.from('predictions').select('created_at').gte('created_at', new Date(Date.now() - 30 * 86400000).toISOString()).order('created_at', { ascending: true }).limit(10000)),
      addFilter(supabase.from('predictions').select('id, leaf_type, predicted_class_name, created_at').order('created_at', { ascending: false }).limit(8)),
      supabase.from('devices').select('*', { count: 'exact', head: true }).in('status', ['online', 'assigned', 'offline']),
    ])

    // Bail out if this request was cancelled (component unmounted or filter changed)
    if (signal?.aborted) return

    const rpcStats = rpcStatsRes.status === 'fulfilled' ? rpcStatsRes.value?.data : null
    const diseaseDist = diseaseDistRes.status === 'fulfilled' ? diseaseDistRes.value?.data : null
    const models = modelsRes.status === 'fulfilled' ? modelsRes.value?.count : 0
    const dailyRows = dailyRowsRes.status === 'fulfilled' ? dailyRowsRes.value?.data : null
    const recent = recentRes.status === 'fulfilled' ? recentRes.value?.data : null
    const activeDevices = devicesRes.status === 'fulfilled' ? devicesRes.value?.count : 0

    // Stats from RPC
    const s = rpcStats || {}
    setStats({
      total: s.total || 0,
      users: s.unique_users || 0,
      models: models || 0,
      devices: activeDevices || 0,
    })

    // Disease distribution from RPC
    if (diseaseDist) {
      const leafCounts = {}
      diseaseDist.forEach(r => { leafCounts[r.type] = (leafCounts[r.type] || 0) + r.count })
      setDiseaseData(
        diseaseDist.map(r => ({ name: cleanLabel(r.name), count: Number(r.count) })).slice(0, 8)
      )
      const total2 = Object.values(leafCounts).reduce((a, b) => a + b, 0) || 1
      setLeafSplit(Object.entries(leafCounts).map(([name, count]) => ({ name, count, pct: ((count / total2) * 100).toFixed(1) })))
    }

    if (dailyRows) {
      const dayCounts = {}
      dailyRows.forEach(r => {
        const day = (r.created_at || '').slice(0, 10)
        dayCounts[day] = (dayCounts[day] || 0) + 1
      })
      setDailyData(Object.entries(dayCounts).sort((a, b) => a[0].localeCompare(b[0])).map(([date, count]) => ({ date: date.slice(5), count })))
    }

    setRecentPreds(recent || [])
    } catch (err) {
      if (err.name !== 'AbortError') setError(err.message)
    }
    if (!signal?.aborted) setLoading(false)
  }

  if (loading) return (
    <div className="loading-spinner">
      <div className="spinner" />
      <span>Loading dashboard...</span>
    </div>
  )

  const statCards = [
    { label: 'Total Predictions', value: stats.total.toLocaleString(), accent: '#16a34a', iconColor: '#16a34a', iconBg: '#dcfce7',
      icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg> },
    { label: 'Users with Predictions', value: stats.users, accent: '#0284c7', iconColor: '#0284c7', iconBg: '#e0f2fe',
      icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 00-3-3.87M16 3.13a4 4 0 010 7.75"/></svg> },
    { label: 'Registered Models', value: stats.models, accent: '#7c3aed', iconColor: '#7c3aed', iconBg: '#ede9fe',
      icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg> },
    { label: 'Active Devices', value: stats.devices, accent: '#e97319', iconColor: '#e97319', iconBg: '#fff7ed',
      icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8m-4-4v4"/></svg> },
  ]

  return (
    <>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h1 className="page-title">Dashboard</h1>
          <p className="page-subtitle">Overview of AgriKD prediction activity and system status</p>
        </div>
        <select value={leafFilter} onChange={e => setLeafFilter(e.target.value)} style={{ padding: '8px 12px', borderRadius: 8, border: '1px solid rgba(0,0,0,0.12)', fontSize: 13, fontWeight: 500, background: 'white', color: '#3d4f62', minWidth: 180 }}>
          <option value="">All Leaf Types</option>
          {leafTypeOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
        </select>
      </div>

      <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
        {statCards.map(s => (
          <div key={s.label} className="stat-card">
            <div className="stat-card-accent" style={{ background: s.accent }} />
            <div className="stat-icon" style={{ background: s.iconBg, color: s.iconColor }}>{s.icon}</div>
            <div className="stat-label">{s.label}</div>
            <div className="stat-value">{s.value}</div>
          </div>
        ))}
      </div>

      <div className="charts-grid">
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-label">Scan Activity</div>
              <div className="card-title">Daily Scans — Last 30 Days</div>
            </div>
          </div>
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={dailyData} margin={{ top: 0, right: 0, left: -20, bottom: 0 }}>
              <defs>
                <linearGradient id="scanGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#16a34a" stopOpacity={0.2}/>
                  <stop offset="95%" stopColor="#16a34a" stopOpacity={0}/>
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="rgba(0,0,0,0.05)" />
              <XAxis dataKey="date" tick={{ fontSize: 11, fill: '#94a3b8' }} axisLine={false} tickLine={false} />
              <YAxis allowDecimals={false} tick={{ fontSize: 11, fill: '#94a3b8' }} axisLine={false} tickLine={false} />
              <Tooltip content={<CustomTooltip />} />
              <Area type="monotone" dataKey="count" name="Scans" stroke="#16a34a" strokeWidth={2} fill="url(#scanGrad)" />
            </AreaChart>
          </ResponsiveContainer>
        </div>

        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-label">Leaf Types</div>
              <div className="card-title">Dataset Split</div>
            </div>
          </div>
          {leafSplit.map((l, i) => (
            <div key={l.name} style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 5, fontSize: 13 }}>
                <span style={{ color: '#3d4f62', fontWeight: 500 }}>{l.name || 'Unknown'}</span>
                <span style={{ color: '#64748b', fontWeight: 600 }}>{l.pct}% <span style={{ fontWeight: 400, color: '#94a3b8' }}>({l.count.toLocaleString()})</span></span>
              </div>
              <div className="progress-track">
                <div className="progress-fill" style={{ width: `${l.pct}%`, background: i === 0 ? '#16a34a' : '#0284c7' }} />
              </div>
            </div>
          ))}
          {leafSplit.length === 0 && <p className="text-muted">No data yet</p>}
        </div>
      </div>

      <div className="card">
        <div className="card-header">
          <div>
            <div className="card-label">Disease Analysis</div>
            <div className="card-title">Top Detected Diseases</div>
          </div>
        </div>
        <ResponsiveContainer width="100%" height={240}>
          <BarChart data={diseaseData} layout="vertical" margin={{ top: 0, right: 16, left: 0, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="rgba(0,0,0,0.05)" />
            <XAxis type="number" tick={{ fontSize: 11, fill: '#94a3b8' }} axisLine={false} tickLine={false} />
            <YAxis dataKey="name" type="category" width={130} tick={{ fontSize: 11, fill: '#3d4f62' }} axisLine={false} tickLine={false} />
            <Tooltip content={<CustomTooltip />} />
            <Bar dataKey="count" name="Predictions" fill="#16a34a" radius={[0, 4, 4, 0]}>
              {diseaseData.map((_, i) => (
                <Cell key={i} fill={`rgba(22,163,74,${1 - i * 0.1})`} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>

      <div className="card">
        <div className="card-header">
          <div>
            <div className="card-label">Recent Activity</div>
            <div className="card-title">Latest Predictions</div>
          </div>
        </div>
        <div className="table-wrapper">
          <table>
            <thead>
              <tr>
                <th>Leaf</th>
                <th>Disease</th>
                <th>Date</th>
              </tr>
            </thead>
            <tbody>
              {recentPreds.map(p => (
                <tr key={p.id}>
                  <td><span className="badge badge-primary">{p.leaf_type}</span></td>
                  <td style={{ maxWidth: 140, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{cleanLabel(p.predicted_class_name)}</td>
                  <td style={{ color: '#94a3b8', fontSize: 12 }}>{new Date(p.created_at).toLocaleDateString()}</td>
                </tr>
              ))}
              {recentPreds.length === 0 && (
                <tr><td colSpan={3} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No predictions yet</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </>
  )
}
