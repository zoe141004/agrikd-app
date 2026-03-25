import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'

const PAGE_SIZE = 25

export default function PredictionsPage() {
  const [predictions, setPredictions] = useState([])
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(0)
  const [total, setTotal] = useState(0)
  const [filters, setFilters] = useState({ leafType: '', startDate: '', endDate: '' })

  useEffect(() => {
    loadPredictions()
  }, [page, filters])

  const loadPredictions = async () => {
    setLoading(true)

    let query = supabase
      .from('predictions')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1)

    if (filters.leafType) query = query.eq('leaf_type', filters.leafType)
    if (filters.startDate) query = query.gte('created_at', filters.startDate)
    if (filters.endDate) query = query.lte('created_at', filters.endDate + 'T23:59:59')

    const { data, count } = await query
    setPredictions(data || [])
    setTotal(count || 0)
    setLoading(false)
  }

  const exportCSV = async () => {
    let query = supabase
      .from('predictions')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(10000)

    if (filters.leafType) query = query.eq('leaf_type', filters.leafType)
    if (filters.startDate) query = query.gte('created_at', filters.startDate)
    if (filters.endDate) query = query.lte('created_at', filters.endDate + 'T23:59:59')

    const { data } = await query
    if (!data || data.length === 0) return

    const headers = ['id', 'user_id', 'leaf_type', 'predicted_class_name', 'confidence', 'latitude', 'longitude', 'notes', 'created_at']
    const csv = [
      headers.join(','),
      ...data.map(r => headers.map(h => JSON.stringify(r[h] ?? '')).join(','))
    ].join('\n')

    const blob = new Blob([csv], { type: 'text/csv' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `agrikd-predictions-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const exportJSON = async () => {
    let query = supabase
      .from('predictions')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(10000)

    if (filters.leafType) query = query.eq('leaf_type', filters.leafType)
    if (filters.startDate) query = query.gte('created_at', filters.startDate)
    if (filters.endDate) query = query.lte('created_at', filters.endDate + 'T23:59:59')

    const { data } = await query
    if (!data) return

    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `agrikd-predictions-${new Date().toISOString().slice(0, 10)}.json`
    a.click()
    URL.revokeObjectURL(url)
  }

  const totalPages = Math.ceil(total / PAGE_SIZE)

  return (
    <>
      <h1 className="page-title">Predictions</h1>

      <div className="filters">
        <select
          value={filters.leafType}
          onChange={(e) => { setPage(0); setFilters({ ...filters, leafType: e.target.value }) }}
        >
          <option value="">All Leaf Types</option>
          <option value="tomato">Tomato</option>
          <option value="burmese_grape_leaf">Burmese Grape Leaf</option>
        </select>
        <input
          type="date"
          value={filters.startDate}
          onChange={(e) => { setPage(0); setFilters({ ...filters, startDate: e.target.value }) }}
          placeholder="Start Date"
        />
        <input
          type="date"
          value={filters.endDate}
          onChange={(e) => { setPage(0); setFilters({ ...filters, endDate: e.target.value }) }}
          placeholder="End Date"
        />
        <button className="btn" onClick={exportCSV}>Export CSV</button>
        <button className="btn" onClick={exportJSON}>Export JSON</button>
      </div>

      <div className="card">
        <p className="text-muted mb-2">
          Showing {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, total)} of {total}
        </p>

        {loading ? <p>Loading...</p> : (
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Leaf Type</th>
                <th>Disease</th>
                <th>Confidence</th>
                <th>Location</th>
                <th>Date</th>
              </tr>
            </thead>
            <tbody>
              {predictions.map(p => (
                <tr key={p.id}>
                  <td>{p.id}</td>
                  <td>{p.leaf_type}</td>
                  <td>{cleanLabel(p.predicted_class_name)}</td>
                  <td>
                    <span className={`badge ${p.confidence >= 0.8 ? 'badge-green' : p.confidence >= 0.5 ? 'badge-yellow' : 'badge-red'}`}>
                      {(p.confidence * 100).toFixed(1)}%
                    </span>
                  </td>
                  <td>
                    {p.latitude && p.longitude
                      ? `${p.latitude.toFixed(3)}, ${p.longitude.toFixed(3)}`
                      : '—'}
                  </td>
                  <td>{new Date(p.created_at).toLocaleDateString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <div style={{ display: 'flex', gap: 8, marginTop: 16, justifyContent: 'center' }}>
          <button className="btn" disabled={page === 0} onClick={() => setPage(p => p - 1)}>Prev</button>
          <span className="text-muted" style={{ padding: '8px 0' }}>Page {page + 1} of {totalPages || 1}</span>
          <button className="btn" disabled={page + 1 >= totalPages} onClick={() => setPage(p => p + 1)}>Next</button>
        </div>
      </div>
    </>
  )
}

function cleanLabel(name) {
  if (!name) return 'Unknown'
  return name.replace(/^[A-Za-z]+___/, '').replace(/_/g, ' ')
}
