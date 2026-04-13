import { useState, useEffect, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { logAudit } from '../lib/helpers'
import { useData } from '../lib/DataContext'
import ConfirmDialog from '../components/ConfirmDialog'

const STATUS_COLORS = {
  online:         { bg: '#dcfce7', text: '#16a34a' },
  assigned:       { bg: '#e0f2fe', text: '#0284c7' },
  offline:        { bg: '#fef3c7', text: '#d97706' },
  unassigned:     { bg: '#f1f5f9', text: '#64748b' },
  decommissioned: { bg: '#fee2e2', text: '#dc2626' },
}

export default function DevicesPage() {
  const { triggerRefresh, refreshKey, leafTypeOptions } = useData()
  const [tab, setTab] = useState('fleet')
  const [devices, setDevices] = useState([])
  const [tokens, setTokens] = useState([])
  const [users, setUsers] = useState([])
  const [modelVersions, setModelVersions] = useState({}) // {leaf_type: [{version, status}]}
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [search, setSearch] = useState('')
  const [editDevice, setEditDevice] = useState(null)
  const [form, setForm] = useState({})
  const [saving, setSaving] = useState(false)
  const [formError, setFormError] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)
  const [tokenLabel, setTokenLabel] = useState('')
  const [generatedToken, setGeneratedToken] = useState('')
  const [successMsg, setSuccessMsg] = useState(null)

  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    loadData()

    // Realtime subscription: auto-refresh when devices table changes
    const channel = supabase
      .channel('devices-realtime')
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'devices',
      }, () => {
        if (mountedRef.current) loadData()
      })
      .subscribe((status) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          console.warn('Devices realtime subscription failed:', status)
        }
      })

    return () => {
      mountedRef.current = false
      supabase.removeChannel(channel)
    }
  }, [refreshKey])

  useEffect(() => {
    if (!successMsg) return
    const t = setTimeout(() => setSuccessMsg(null), 4000)
    return () => clearTimeout(t)
  }, [successMsg])

  const loadData = async () => {
    setLoading(true)
    setError(null)
    try {
      const [devRes, tokRes, usersRes, modelsRes] = await Promise.allSettled([
        supabase.from('devices').select('*').order('created_at', { ascending: false }).limit(200),
        supabase.from('provisioning_tokens').select('*').order('created_at', { ascending: false }).limit(50),
        supabase.from('profiles').select('id, email, role').eq('role', 'user').order('email').limit(200),
        supabase.from('model_registry').select('leaf_type, version, status').in('status', ['active', 'staging']).order('leaf_type').order('version', { ascending: false }),
      ])
      if (!mountedRef.current) return
      if (devRes.status === 'fulfilled' && devRes.value.data) setDevices(devRes.value.data)
      else if (devRes.status === 'fulfilled' && devRes.value.error) setError(devRes.value.error.message)
      if (tokRes.status === 'fulfilled' && tokRes.value.data) setTokens(tokRes.value.data)
      if (usersRes.status === 'fulfilled' && usersRes.value.data) setUsers(usersRes.value.data)
      // Group model versions by leaf_type
      if (modelsRes.status === 'fulfilled' && modelsRes.value.data) {
        const grouped = {}
        for (const m of modelsRes.value.data) {
          if (!grouped[m.leaf_type]) grouped[m.leaf_type] = []
          grouped[m.leaf_type].push({ version: m.version, status: m.status })
        }
        setModelVersions(grouped)
      }
    } catch (err) {
      if (mountedRef.current) setError(err.message)
    }
    if (mountedRef.current) setLoading(false)
  }

  // ── Fleet Tab ──────────────────────────────────────────────────

  const openEdit = (d) => {
    // Build model_versions form from desired_config or defaults
    const mv = d.desired_config?.model_versions || {}
    const formMv = {}
    for (const lt of leafTypeOptions) {
      formMv[lt] = mv[lt] || ''  // empty = "latest active"
    }
    setForm({
      device_name: d.device_name || '',
      user_id: d.user_id || '',
      mode: d.desired_config?.mode || 'manual',
      interval_seconds: d.desired_config?.interval_seconds || 86400,
      default_leaf_type: d.desired_config?.default_leaf_type || 'tomato',
      model_versions: formMv,
    })
    setFormError(null)
    setEditDevice(d)
  }

  const saveDevice = async () => {
    setSaving(true)
    // Resolve model_versions: empty string means "latest active" — look up actual version
    const mv = {}
    for (const [lt, ver] of Object.entries(form.model_versions || {})) {
      if (ver) {
        mv[lt] = ver
      } else {
        // Resolve "Latest active" to the actual latest active version
        const versions = modelVersions[lt] || []
        const latestActive = versions.find(v => v.status === 'active')
        if (latestActive) mv[lt] = latestActive.version
      }
    }
    const update = {
      device_name: form.device_name || null,
      user_id: form.user_id || null,
      status: form.user_id ? 'assigned' : 'unassigned',
      desired_config: {
        mode: form.mode,
        interval_seconds: Number(form.interval_seconds),
        default_leaf_type: form.default_leaf_type,
        model_versions: mv,
      },
    }
    const { error: err } = await supabase.from('devices').update(update).eq('id', editDevice.id)
    setSaving(false)
    if (!err) {
      logAudit(supabase, 'device_updated', 'device', editDevice.id, { device_name: form.device_name, user_id: form.user_id })
      setEditDevice(null); setFormError(null)
      setSuccessMsg(`Device "${form.device_name || editDevice.hostname}" updated`)
      loadData(); triggerRefresh()
    } else {
      setFormError(err.message)
    }
  }

  const decommission = (d) => {
    setConfirmAction({
      title: 'Decommission Device',
      message: `Decommission "${d.device_name || d.hostname}"? This will unassign the user and prevent the device from syncing.`,
      danger: true,
      confirmLabel: 'Decommission',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error: err } = await supabase.from('devices')
          .update({ status: 'decommissioned', user_id: null })
          .eq('id', d.id)
        if (!err) {
          logAudit(supabase, 'device_decommissioned', 'device', d.id, { hostname: d.hostname })
          setSuccessMsg(`Device "${d.device_name || d.hostname}" decommissioned`)
          loadData(); triggerRefresh()
        } else setError(err.message)
      }
    })
  }

  // ── Tokens Tab ──────────────────────────────────────────────────

  const generateToken = async () => {
    setSaving(true)
    setError(null)
    try {
      const { data: sessionData } = await supabase.auth.getSession()
      const userId = sessionData?.session?.user?.id
      if (!userId) throw new Error('Not authenticated')

      const { data, error: err } = await supabase.from('provisioning_tokens')
        .insert({ created_by: userId, label: tokenLabel || null })
        .select()
        .single()
      if (err) throw err

      // Build agrikd:// token
      const url = import.meta.env.VITE_SUPABASE_URL || supabase.supabaseUrl
      const key = import.meta.env.VITE_SUPABASE_ANON_KEY || supabase.supabaseKey
      const exp = Math.floor(new Date(data.expires_at).getTime() / 1000)
      const payload = JSON.stringify({ url, key, tid: data.id, exp })
      const encoded = btoa(payload)
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
      setGeneratedToken(`agrikd://${encoded}`)
      setTokenLabel('')
      loadData(); triggerRefresh()
    } catch (err) { setError(err.message) }
    setSaving(false)
  }

  const revokeToken = (t) => {
    setConfirmAction({
      title: 'Revoke Token',
      message: `Revoke provisioning token "${t.label || t.id.slice(0, 8)}"? It will no longer be usable.`,
      danger: true,
      confirmLabel: 'Revoke',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error: err } = await supabase.from('provisioning_tokens').delete().eq('id', t.id)
        if (!err) {
          setSuccessMsg(`Token "${t.label || t.id.slice(0, 8)}" revoked`)
          loadData(); triggerRefresh()
        } else setError(err.message)
      }
    })
  }

  const filteredDevices = devices.filter(d =>
    !search ||
    (d.device_name || '').toLowerCase().includes(search.toLowerCase()) ||
    (d.hostname || '').toLowerCase().includes(search.toLowerCase()) ||
    (d.hw_id || '').toLowerCase().includes(search.toLowerCase())
  )

  const statCounts = {
    total: devices.length,
    online: devices.filter(d => d.status === 'online').length,
    assigned: devices.filter(d => ['online', 'assigned', 'offline'].includes(d.status)).length,
    unassigned: devices.filter(d => d.status === 'unassigned').length,
  }

  if (loading) return (
    <div className="loading-spinner"><div className="spinner" /><span>Loading devices...</span></div>
  )

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Devices</h1>
        <p className="page-subtitle">Manage Jetson edge devices and provisioning tokens</p>
      </div>

      {error && (
        <div className="alert alert-error" style={{ marginBottom: 16 }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>
          <div style={{ flex: 1 }}>{error}</div>
          <button onClick={() => setError(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 16, padding: '0 4px' }}>×</button>
        </div>
      )}

      {successMsg && (
        <div className="alert alert-success" style={{ marginBottom: 16 }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
          <div style={{ flex: 1 }}>{successMsg}</div>
          <button onClick={() => setSuccessMsg(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 16, padding: '0 4px' }}>×</button>
        </div>
      )}

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 20 }}>
        {['fleet', 'tokens'].map(t => (
          <button
            key={t}
            className={`btn ${tab === t ? 'btn-primary' : ''}`}
            onClick={() => setTab(t)}
            style={tab !== t ? { background: '#f1f5f9', color: '#3d4f62' } : {}}
          >
            {t === 'fleet' ? 'Device Fleet' : 'Provisioning Tokens'}
          </button>
        ))}
      </div>

      {tab === 'fleet' && (
        <>
          {/* Stats */}
          <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(4, 1fr)', marginBottom: 16 }}>
            {[
              { label: 'Total Devices', value: statCounts.total, accent: '#64748b' },
              { label: 'Online', value: statCounts.online, accent: '#16a34a' },
              { label: 'Assigned', value: statCounts.assigned, accent: '#0284c7' },
              { label: 'Unassigned', value: statCounts.unassigned, accent: '#d97706' },
            ].map(s => (
              <div key={s.label} className="stat-card">
                <div className="stat-card-accent" style={{ background: s.accent }} />
                <div className="stat-label">{s.label}</div>
                <div className="stat-value">{s.value}</div>
              </div>
            ))}
          </div>

          {/* Search */}
          <div style={{ marginBottom: 16 }}>
            <input
              type="text"
              className="input"
              placeholder="Search by name, hostname, or hw_id..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              style={{ maxWidth: 360 }}
            />
          </div>

          {/* Devices table */}
          <div className="card">
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Hostname</th>
                    <th>Status</th>
                    <th>Owner</th>
                    <th>Last Seen</th>
                    <th>Config</th>
                    <th>Models</th>
                    <th style={{ width: 120 }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredDevices.map(d => {
                    const sc = STATUS_COLORS[d.status] || STATUS_COLORS.unassigned
                    const owner = users.find(u => u.id === d.user_id)
                    const synced = (() => {
                      if (!d.desired_config || !d.reported_config) return false
                      // Compare ignoring engine_status and applied_model_versions (Jetson-added fields)
                      const { engine_status, applied_model_versions, ...repCore } = d.reported_config
                      return JSON.stringify(d.desired_config) === JSON.stringify(repCore)
                    })()
                    const hasDesired = !!d.desired_config
                    const configLabel = !hasDesired ? 'N/A' : synced ? 'Synced' : 'Pending'
                    const configColor = !hasDesired ? '#94a3b8' : synced ? '#16a34a' : '#d97706'
                    const configTitle = !hasDesired
                      ? 'No configuration set for this device'
                      : synced
                        ? 'Device has acknowledged the current configuration'
                        : 'Device has not yet applied the latest configuration changes'
                    return (
                      <tr key={d.id}>
                        <td style={{ fontWeight: 500 }}>{d.device_name || '—'}</td>
                        <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{d.hostname}</td>
                        <td>
                          <span className="badge" style={{ background: sc.bg, color: sc.text }}>{d.status}</span>
                        </td>
                        <td style={{ fontSize: 12 }}>{owner?.email || (d.user_id ? d.user_id.slice(0, 8) : '—')}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>
                          {d.last_seen_at ? new Date(d.last_seen_at).toLocaleString() : '—'}
                        </td>
                        <td>
                          <span title={configTitle} style={{ color: configColor, fontSize: 12, cursor: 'help' }}>{configLabel}</span>
                        </td>
                        <td style={{ fontSize: 11 }}>
                          {(() => {
                            const mv = d.reported_config?.applied_model_versions || d.desired_config?.model_versions || {}
                            const es = d.reported_config?.engine_status || {}
                            const entries = Object.entries(mv)
                            if (entries.length === 0) return <span style={{ color: '#94a3b8' }}>—</span>
                            return entries.map(([lt, v]) => {
                              const statusColor = es[lt] === 'ready' ? '#16a34a' : es[lt] === 'building' ? '#d97706' : es[lt] === 'error' ? '#dc2626' : '#64748b'
                              return <div key={lt}><strong>{lt}</strong>: v{v} <span style={{ color: statusColor }}>{es[lt] ? `(${es[lt]})` : ''}</span></div>
                            })
                          })()}
                        </td>
                        <td>
                          <div style={{ display: 'flex', gap: 4 }}>
                            <button className="btn" style={{ padding: '4px 8px', fontSize: 11 }} onClick={() => openEdit(d)}>Edit</button>
                            {d.status !== 'decommissioned' && (
                              <button className="btn" style={{ padding: '4px 8px', fontSize: 11, color: '#dc2626' }} onClick={() => decommission(d)}>Decom</button>
                            )}
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                  {filteredDevices.length === 0 && (
                    <tr><td colSpan={8} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No devices registered yet</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {tab === 'tokens' && (
        <>
          {/* Generate Token */}
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header">
              <div>
                <div className="card-label">Provisioning</div>
                <div className="card-title">Generate New Token</div>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end', padding: '0 0 16px' }}>
              <div style={{ flex: 1, maxWidth: 300 }}>
                <label style={{ fontSize: 12, color: '#64748b', display: 'block', marginBottom: 4 }}>Label (optional)</label>
                <input
                  className="input"
                  placeholder='e.g. "Tomato Garden #3"'
                  value={tokenLabel}
                  onChange={e => setTokenLabel(e.target.value)}
                />
              </div>
              <button className="btn btn-primary" onClick={generateToken} disabled={saving}>
                {saving ? 'Generating...' : 'Generate Token'}
              </button>
            </div>

            {generatedToken && (
              <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 8, padding: 16, marginBottom: 8 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: '#16a34a', marginBottom: 8 }}>
                  Token Generated — Copy and send to technician
                </div>
                <div style={{ fontFamily: 'monospace', fontSize: 11, wordBreak: 'break-all', background: 'white', padding: 12, borderRadius: 6, border: '1px solid #dcfce7', marginBottom: 8 }}>
                  {generatedToken}
                </div>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => { navigator.clipboard.writeText(generatedToken); }}>
                  Copy to Clipboard
                </button>
              </div>
            )}
          </div>

          {/* Tokens table */}
          <div className="card">
            <div className="card-header">
              <div>
                <div className="card-label">History</div>
                <div className="card-title">Provisioning Tokens</div>
              </div>
            </div>
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Label</th>
                    <th>Status</th>
                    <th>Expires</th>
                    <th>Used By</th>
                    <th style={{ width: 80 }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {tokens.map(t => {
                    const used = !!t.used_at
                    const expired = !used && new Date(t.expires_at) < new Date()
                    const statusLabel = used ? 'Used' : expired ? 'Expired' : 'Active'
                    const statusColor = used ? '#16a34a' : expired ? '#dc2626' : '#0284c7'
                    return (
                      <tr key={t.id}>
                        <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{t.id.slice(0, 8)}...</td>
                        <td>{t.label || '—'}</td>
                        <td><span className="badge" style={{ background: `${statusColor}15`, color: statusColor }}>{statusLabel}</span></td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{new Date(t.expires_at).toLocaleString()}</td>
                        <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{t.used_by_hw_id ? t.used_by_hw_id.slice(0, 12) + '...' : '—'}</td>
                        <td>
                          {!used && !expired && (
                            <button className="btn" style={{ padding: '4px 8px', fontSize: 11, color: '#dc2626' }} onClick={() => revokeToken(t)}>Revoke</button>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                  {tokens.length === 0 && (
                    <tr><td colSpan={6} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No tokens generated yet</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {/* Edit Device Modal */}
      {editDevice && (
        <div className="modal-overlay" onClick={() => setEditDevice(null)}>
          <div className="modal" onClick={e => e.stopPropagation()} style={{ maxWidth: 480 }}>
            <div className="modal-header">
              <h3>Edit Device: {editDevice.hostname}</h3>
              <button className="btn" onClick={() => setEditDevice(null)} style={{ padding: '4px 8px' }}>×</button>
            </div>
            <div className="modal-body">
              <div style={{ marginBottom: 12 }}>
                <label className="form-label">Device Name</label>
                <input
                  className="input"
                  value={form.device_name}
                  onChange={e => setForm(f => ({ ...f, device_name: e.target.value }))}
                  placeholder="e.g. Tomato Garden #3"
                />
              </div>
              <div style={{ marginBottom: 12 }}>
                <label className="form-label">Assign User</label>
                <select
                  className="input"
                  value={form.user_id}
                  onChange={e => setForm(f => ({ ...f, user_id: e.target.value }))}
                >
                  <option value="">Unassigned</option>
                  {users.map(u => <option key={u.id} value={u.id}>{u.email}</option>)}
                </select>
              </div>
              <div style={{ marginBottom: 12 }}>
                <label className="form-label">Capture Mode</label>
                <select
                  className="input"
                  value={form.mode}
                  onChange={e => setForm(f => ({ ...f, mode: e.target.value }))}
                >
                  <option value="manual">Manual</option>
                  <option value="periodic">Periodic</option>
                </select>
              </div>
              {form.mode === 'periodic' && (
                <div style={{ marginBottom: 12 }}>
                  <label className="form-label">Interval (seconds)</label>
                  <select
                    className="input"
                    value={form.interval_seconds}
                    onChange={e => setForm(f => ({ ...f, interval_seconds: Number(e.target.value) }))}
                  >
                    <option value={60}>1 minute</option>
                    <option value={300}>5 minutes</option>
                    <option value={900}>15 minutes</option>
                    <option value={1800}>30 minutes</option>
                    <option value={3600}>1 hour</option>
                    <option value={21600}>6 hours</option>
                    <option value={86400}>24 hours</option>
                  </select>
                </div>
              )}
              <div style={{ marginBottom: 12 }}>
                <label className="form-label">Default Leaf Type</label>
                <select
                  className="form-input"
                  value={form.default_leaf_type}
                  onChange={e => setForm(f => ({ ...f, default_leaf_type: e.target.value }))}
                >
                  {leafTypeOptions.map(lt => <option key={lt} value={lt}>{lt.replace(/_/g, ' ')}</option>)}
                  {!leafTypeOptions.includes(form.default_leaf_type) && form.default_leaf_type && (
                    <option value={form.default_leaf_type}>{form.default_leaf_type}</option>
                  )}
                </select>
              </div>
              {/* Model Version Assignment */}
              <div style={{ marginBottom: 12 }}>
                <label className="form-label">Model Versions</label>
                <div style={{ border: '1px solid #e2e8f0', borderRadius: 6, padding: 8 }}>
                  {leafTypeOptions.map(lt => {
                    const versions = modelVersions[lt] || []
                    return (
                      <div key={lt} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                        <span style={{ minWidth: 140, fontSize: 13 }}>{lt.replace(/_/g, ' ')}</span>
                        <select
                          className="input"
                          style={{ flex: 1, fontSize: 12 }}
                          value={(form.model_versions || {})[lt] || ''}
                          onChange={e => setForm(f => ({
                            ...f,
                            model_versions: { ...f.model_versions, [lt]: e.target.value }
                          }))}
                        >
                          <option value="">Latest active</option>
                          {versions.map(v => (
                            <option key={v.version} value={v.version}>
                              v{v.version} ({v.status})
                            </option>
                          ))}
                        </select>
                      </div>
                    )
                  })}
                  {leafTypeOptions.length === 0 && (
                    <span style={{ color: '#94a3b8', fontSize: 12 }}>No models available</span>
                  )}
                </div>
              </div>
              {/* Engine Status */}
              {editDevice.reported_config?.engine_status && (
                <div style={{ marginBottom: 12, padding: 8, background: '#fffbeb', borderRadius: 6, fontSize: 12 }}>
                  <strong>Engine Status:</strong>{' '}
                  {Object.entries(editDevice.reported_config?.engine_status || {}).map(([lt, s]) => (
                    <span key={lt} style={{ marginRight: 12 }}>
                      {lt}: <strong style={{ color: s === 'ready' ? '#16a34a' : s === 'building' ? '#d97706' : '#dc2626' }}>{s}</strong>
                    </span>
                  ))}
                </div>
              )}
              <div style={{ marginTop: 8, padding: 8, background: '#f8fafc', borderRadius: 6, fontSize: 11, color: '#64748b' }}>
                <strong>HW ID:</strong> {editDevice.hw_id}<br/>
                <strong>Platform:</strong> {editDevice.hw_info?.platform || '—'}<br/>
                <strong>Registered:</strong> {new Date(editDevice.created_at).toLocaleString()}
              </div>
            </div>
            <div className="modal-footer">
              {formError && <div className="alert alert-danger" style={{ marginBottom: 8, fontSize: 13 }}>{formError}</div>}
              <button className="btn" onClick={() => setEditDevice(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveDevice} disabled={saving}>
                {saving ? 'Saving...' : 'Save Changes'}
              </button>
            </div>
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}
