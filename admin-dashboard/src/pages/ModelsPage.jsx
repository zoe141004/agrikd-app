import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'

export default function ModelsPage() {
  const [models, setModels] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadModels()
  }, [])

  const loadModels = async () => {
    setLoading(true)
    const { data } = await supabase
      .from('model_registry')
      .select('*')
      .order('leaf_type', { ascending: true })

    setModels(data || [])
    setLoading(false)
  }

  if (loading) return <p>Loading...</p>

  return (
    <>
      <h1 className="page-title">Model Registry</h1>

      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Leaf Type</th>
              <th>Display Name</th>
              <th>Version</th>
              <th>Classes</th>
              <th>Accuracy</th>
              <th>SHA-256</th>
              <th>Updated</th>
            </tr>
          </thead>
          <tbody>
            {models.map(m => (
              <tr key={m.id}>
                <td><strong>{m.leaf_type}</strong></td>
                <td>{m.display_name}</td>
                <td><span className="badge badge-green">v{m.version}</span></td>
                <td>{m.num_classes}</td>
                <td>{m.accuracy_top1 ? `${m.accuracy_top1}%` : '—'}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 12 }}>
                  {m.sha256_checksum ? m.sha256_checksum.slice(0, 16) + '...' : '—'}
                </td>
                <td>{new Date(m.updated_at).toLocaleDateString()}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3>Class Labels</h3>
        {models.map(m => (
          <div key={m.id} style={{ marginBottom: 16 }}>
            <strong>{m.display_name}</strong> ({m.num_classes} classes)
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginTop: 6 }}>
              {(Array.isArray(m.class_labels) ? m.class_labels : []).map((label, i) => (
                <span key={i} className="badge badge-green" style={{ background: label.toLowerCase().includes('healthy') ? '#dcfce7' : '#f1f5f9', color: label.toLowerCase().includes('healthy') ? '#16a34a' : '#475569' }}>
                  {i}: {label.replace(/_/g, ' ')}
                </span>
              ))}
            </div>
          </div>
        ))}
      </div>
    </>
  )
}
