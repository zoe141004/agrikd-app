import { useState, useEffect } from 'react'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import { supabase } from '../lib/supabase'
import { cleanLabel, downloadFile } from '../lib/helpers'
import CustomTooltip from '../components/CustomTooltip'

const PAGE_SIZE = 25

export default function PredictionsPage() {
  const [predictions, setPredictions] = useState([])
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(0)
  const [total, setTotal] = useState(0)
  const [filters, setFilters] = useState({ leafType: '', startDate: '', endDate: '' })
  const [selected, setSelected] = useState(null)
  const [error, setError] = useState(null)
  const [summary, setSummary] = useState({ topDisease: '—', uniqueUsers: 0 })
  const [classDist, setClassDist] = useState([])

  useEffect(() => { loadPredictions() }, [page, filters])

  const applyFilters = (query) => {
    if (filters.leafType) query = query.eq('leaf_type', filters.leafType)
    if (filters.startDate) query = query.gte('created_at', filters.startDate)
    if (filters.endDate) query = query.lte('created_at', filters.endDate + 'T23:59:59')
    return query
  }

  const loadPredictions = async () => {
    setLoading(true)
    setError(null)
    try {
    const rpcFilter = filters.leafType || null

    const [{ data, count }, { data: rpcStats }, { data: diseaseDist }] = await Promise.all([
      applyFilters(
        supabase.from('predictions').select('*', { count: 'exact' })
          .order('created_at', { ascending: false })
          .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1)
      ),
      supabase.rpc('get_dashboard_stats', { p_leaf_type: rpcFilter }),
      supabase.rpc('get_disease_distribution', { p_leaf_type: rpcFilter }),
    ])

    setPredictions(data || [])
    setTotal(count || 0)

    const s = rpcStats || {}
    if (s.total) {
      const topDisease = diseaseDist?.length ? `${cleanLabel(diseaseDist[0].name)} (${diseaseDist[0].count})` : '—'
      setClassDist((diseaseDist || []).map(r => ({ name: cleanLabel(r.name), count: Number(r.count) })))
      setSummary({
        topDisease,
        uniqueUsers: s.unique_users || 0,
      })
    } else {
      setSummary({ topDisease: '—', uniqueUsers: 0 })
      setClassDist([])
    }
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  const setFilter = (key, val) => { setPage(0); setFilters(f => ({ ...f, [key]: val })) }

  const exportData = async (fmt) => {
    try {
    let query = supabase.from('predictions').select('*').order('created_at', { ascending: false }).limit(10000)
    if (filters.leafType) query = query.eq('leaf_type', filters.leafType)
    if (filters.startDate) query = query.gte('created_at', filters.startDate)
    if (filters.endDate) query = query.lte('created_at', filters.endDate + 'T23:59:59')
    const { data } = await query
    if (!data?.length) return
    const filename = `agrikd-predictions-${new Date().toISOString().slice(0, 10)}`
    if (fmt === 'csv') {
      const headers = ['id', 'user_id', 'leaf_type', 'predicted_class_name', 'confidence', 'notes', 'model_version', 'created_at']
      const csv = [headers.join(','), ...data.map(r => headers.map(h => JSON.stringify(r[h] ?? '')).join(','))].join('\n')
      downloadFile(csv, `${filename}.csv`, 'text/csv')
    } else {
      downloadFile(JSON.stringify(data, null, 2), `${filename}.json`, 'application/json')
    }
    } catch (err) { setError('Export failed: ' + err.message) }
  }

  const totalPages = Math.ceil(total / PAGE_SIZE)

  return (
    <>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      <div className="page-header">
        <h1 className="page-title">Predictions</h1>
        <p className="page-subtitle">Browse and export all leaf disease prediction records</p>
      </div>

      <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(2, 1fr)', marginBottom: 16 }}>
        {[
          { label: 'Total Records', value: total.toLocaleString(), accent: '#16a34a' },
          { label: 'Unique Users', value: summary.uniqueUsers, accent: '#7c3aed' },
        ].map(s => (
          <div key={s.label} className="stat-card" style={{ padding: '14px 16px' }}>
            <div className="stat-card-accent" style={{ background: s.accent }} />
            <div className="stat-label">{s.label}</div>
            <div className="stat-value" style={{ fontSize: 22 }}>{s.value}</div>
          </div>
        ))}
      </div>

      {total > 0 && (
        <div className="card" style={{ marginBottom: 16, padding: '12px 16px' }}>
          <div style={{ fontSize: 13, color: '#3d4f62' }}>
            <strong style={{ color: '#121c28' }}>Most Detected:</strong> {summary.topDisease}
          </div>
        </div>
      )}

      {classDist.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-header">
            <div>
              <div className="card-label">Class Distribution</div>
              <div className="card-title">Predictions by Disease Class{filters.leafType ? ` — ${filters.leafType}` : ''}</div>
            </div>
          </div>
          <ResponsiveContainer width="100%" height={Math.max(180, classDist.length * 32)}>
            <BarChart data={classDist} layout="vertical" margin={{ top: 0, right: 16, left: 0, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="rgba(0,0,0,0.05)" />
              <XAxis type="number" tick={{ fontSize: 11, fill: '#94a3b8' }} axisLine={false} tickLine={false} />
              <YAxis dataKey="name" type="category" width={150} tick={{ fontSize: 11, fill: '#3d4f62' }} axisLine={false} tickLine={false} />
              <Tooltip content={<CustomTooltip />} />
              <Bar dataKey="count" name="Predictions" fill="#16a34a" radius={[0, 4, 4, 0]}>
                {classDist.map((_, i) => <Cell key={i} fill={`rgba(22,163,74,${Math.max(0.3, 1 - i * 0.08)})`} />)}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      <div className="card">
        <div className="filters">
          <select value={filters.leafType} onChange={e => setFilter('leafType', e.target.value)}>
            <option value="">All Leaf Types</option>
            <option value="tomato">Tomato</option>
            <option value="burmese_grape_leaf">Burmese Grape Leaf</option>
          </select>
          <input type="date" value={filters.startDate} onChange={e => setFilter('startDate', e.target.value)} />
          <input type="date" value={filters.endDate} onChange={e => setFilter('endDate', e.target.value)} />
          <button className="btn" onClick={() => exportData('csv')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
            Export CSV
          </button>
          <button className="btn" onClick={() => exportData('json')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
            Export JSON
          </button>
        </div>

        {loading ? (
          <div className="loading-spinner"><div className="spinner" /></div>
        ) : (
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Leaf Type</th>
                  <th>Disease</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {predictions.map(p => (
                  <tr key={p.id} style={{ cursor: 'pointer' }} onClick={() => setSelected(selected?.id === p.id ? null : p)}>
                    <td className="font-mono" style={{ color: '#94a3b8' }}>{String(p.id).slice(0, 8)}…</td>
                    <td><span className="badge badge-primary">{p.leaf_type}</span></td>
                    <td>{cleanLabel(p.predicted_class_name)}</td>
                    <td style={{ color: '#64748b', fontSize: 12 }}>{new Date(p.created_at).toLocaleDateString()}</td>
                  </tr>
                ))}
                {predictions.length === 0 && (
                  <tr><td colSpan={4} style={{ textAlign: 'center', padding: 32, color: '#94a3b8' }}>No predictions found</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}

        <div className="pagination">
          <span className="pagination-info">Showing {total === 0 ? 0 : page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, total)} of {total.toLocaleString()} records</span>
          <div className="pagination-controls">
            <button className="btn btn-sm" disabled={page === 0} onClick={() => setPage(0)}>«</button>
            <button className="btn btn-sm" disabled={page === 0} onClick={() => setPage(p => p - 1)}>‹ Prev</button>
            <span style={{ padding: '4px 10px', fontSize: 13, color: '#64748b' }}>Page {page + 1} of {totalPages || 1}</span>
            <button className="btn btn-sm" disabled={page + 1 >= totalPages} onClick={() => setPage(p => p + 1)}>Next ›</button>
            <button className="btn btn-sm" disabled={page + 1 >= totalPages} onClick={() => setPage(totalPages - 1)}>»</button>
          </div>
        </div>
      </div>

      {selected && (
        <div className="modal-overlay" onClick={() => setSelected(null)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">Prediction Detail</span>
              <button className="modal-close" onClick={() => setSelected(null)}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M6 18L18 6M6 6l12 12"/></svg>
              </button>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px 16px', fontSize: 13 }}>
              {[
                ['ID', selected.id],
                ['User ID', selected.user_id],
                ['Leaf Type', selected.leaf_type],
                ['Disease', cleanLabel(selected.predicted_class_name)],
                ['Model Version', selected.model_version || '—'],
                ['Date', new Date(selected.created_at).toLocaleString()],
                ['Notes', selected.notes || '—'],
              ].map(([k, v]) => (
                <div key={k}>
                  <div style={{ fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', color: '#94a3b8', marginBottom: 2 }}>{k}</div>
                  <div style={{ color: '#121c28', wordBreak: 'break-all' }}>{v}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  )
}
