import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'
import { cleanLabel, formatDateTime } from '../lib/helpers'

export default function ModelReportsPage() {
  const [reports, setReports] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [leafFilter, setLeafFilter] = useState('')
  const [versionFilter, setVersionFilter] = useState('')
  const [leafOptions, setLeafOptions] = useState([])
  const [versionOptions, setVersionOptions] = useState([])
  const [stats, setStats] = useState([])

  useEffect(() => { loadReports() }, [leafFilter, versionFilter])

  const loadReports = async () => {
    setLoading(true)
    setError(null)
    try {
      let query = supabase
        .from('model_reports')
        .select('*, predictions(leaf_type, predicted_class_name)')
        .order('created_at', { ascending: false })
        .limit(200)

      if (leafFilter) query = query.eq('leaf_type', leafFilter)
      if (versionFilter) query = query.eq('model_version', versionFilter)

      const { data, error: fetchErr } = await query
      if (fetchErr) throw fetchErr

      setReports(data || [])

      // Build filter options from all reports (unfiltered)
      if (!leafFilter && !versionFilter) {
        const leaves = [...new Set((data || []).map(r => r.leaf_type).filter(Boolean))]
        const versions = [...new Set((data || []).map(r => r.model_version).filter(Boolean))]
        setLeafOptions(leaves.sort())
        setVersionOptions(versions.sort())

        // Aggregate: reports per version
        const versionCounts = {}
        ;(data || []).forEach(r => {
          const key = `${r.leaf_type} v${r.model_version}`
          versionCounts[key] = (versionCounts[key] || 0) + 1
        })
        setStats(
          Object.entries(versionCounts)
            .sort((a, b) => b[1] - a[1])
            .map(([name, count]) => ({ name, count }))
        )
      }
    } catch (err) {
      setError(err.message)
    }
    setLoading(false)
  }

  return (
    <>
      {error && (
        <div className="alert alert-error" style={{ marginBottom: 16 }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>
          <div>{error}</div>
        </div>
      )}

      <div className="page-header">
        <h1 className="page-title">Model Reports</h1>
        <p className="page-subtitle">User-submitted reports of incorrect model predictions</p>
      </div>

      {/* Stats */}
      {stats.length > 0 && (
        <div className="card" style={{ marginBottom: 16, padding: '12px 16px' }}>
          <div style={{ fontSize: 13, color: '#3d4f62' }}>
            <strong style={{ color: '#121c28' }}>Reports by version:</strong>{' '}
            {stats.slice(0, 5).map((s, i) => (
              <span key={s.name}>
                {i > 0 && <span style={{ color: '#94a3b8', margin: '0 8px' }}>|</span>}
                {s.name}: <strong>{s.count}</strong>
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Filters */}
      <div className="card">
        <div className="filters" style={{ marginBottom: 12 }}>
          <select value={leafFilter} onChange={e => setLeafFilter(e.target.value)}>
            <option value="">All Leaf Types</option>
            {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
          </select>
          <select value={versionFilter} onChange={e => setVersionFilter(e.target.value)}>
            <option value="">All Versions</option>
            {versionOptions.map(v => <option key={v} value={v}>v{v}</option>)}
          </select>
          <span style={{ fontSize: 13, color: '#94a3b8' }}>{reports.length} report{reports.length !== 1 ? 's' : ''}</span>
        </div>

        {loading ? (
          <div className="loading-spinner"><div className="spinner" /></div>
        ) : (
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Leaf Type</th>
                  <th>Model Version</th>
                  <th>Prediction</th>
                  <th>Reason</th>
                  <th>User</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {reports.map(r => (
                  <tr key={r.id}>
                    <td><span className="badge badge-primary">{r.leaf_type}</span></td>
                    <td><span className="badge badge-gray">v{r.model_version}</span></td>
                    <td>
                      {r.predictions ? (
                        <span>
                          {cleanLabel(r.predictions.predicted_class_name)}
                        </span>
                      ) : (
                        <span style={{ color: '#94a3b8' }}>#{r.prediction_id || '—'}</span>
                      )}
                    </td>
                    <td style={{ maxWidth: 220, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 13 }}>
                      {r.reason}
                    </td>
                    <td className="font-mono" style={{ color: '#94a3b8', fontSize: 11 }}>
                      {r.user_id ? String(r.user_id).slice(0, 8) + '…' : '—'}
                    </td>
                    <td style={{ fontSize: 12, color: '#64748b' }}>{formatDateTime(r.created_at)}</td>
                  </tr>
                ))}
                {reports.length === 0 && (
                  <tr><td colSpan={6} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>No reports yet. Users can report wrong predictions from the mobile app.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  )
}
