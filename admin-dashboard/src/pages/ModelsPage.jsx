import { useState, useEffect, Fragment, useRef } from 'react'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import { supabase } from '../lib/supabase'
import { cleanLabel, formatBytes, uploadToStorage, ensureBucket, triggerGitHubWorkflow, getGitHubWorkflowRuns, getGitHubConfig, logAudit } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'
import CustomTooltip from '../components/CustomTooltip'

const TABS = ['Registry', 'Benchmarks', 'Upload Model', 'Validate', 'OTA Deploy']

export default function ModelsPage() {
  const [tab, setTab] = useState('Registry')
  const [models, setModels] = useState([])
  const [loading, setLoading] = useState(true)
  const [editModal, setEditModal] = useState(null)
  const [validateResult, setValidateResult] = useState({})
  const [validating, setValidating] = useState({})
  const [form, setForm] = useState({})
  const [saving, setSaving] = useState(false)
  const [expandedId, setExpandedId] = useState(null)

  // Upload state
  const [uploadForm, setUploadForm] = useState({ leaf_type: '', display_name: '', version: '1.0.0', description: '', num_classes: '', class_labels_raw: '', is_new_leaf: false })
  const [uploadFile, setUploadFile] = useState(null)
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState(0)
  const [uploadMsg, setUploadMsg] = useState(null)
  const fileInputRef = useRef()

  // Validation (GitHub Actions)
  const [valTarget, setValTarget] = useState('')
  const [valRunning, setValRunning] = useState(false)
  const [valMsg, setValMsg] = useState(null)
  const [ghRuns, setGhRuns] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)
  const [error, setError] = useState(null)

  // Benchmarks
  const [benchmarks, setBenchmarks] = useState([])
  const [benchLoading, setBenchLoading] = useState(false)

  // Version history
  const [versions, setVersions] = useState([])
  const [expandedVersions, setExpandedVersions] = useState(null)

  useEffect(() => { loadModels() }, [])

  const loadModels = async () => {
    setLoading(true)
    try {
      const [{ data, error: err }, { data: benchData }, { data: verData }] = await Promise.all([
        supabase.from('model_registry').select('*').order('leaf_type', { ascending: true }),
        supabase.from('model_benchmarks').select('*').order('created_at', { ascending: false }),
        supabase.from('model_versions').select('*').order('archived_at', { ascending: false }),
      ])
      if (err) throw new Error(err.message)
      setModels(data || [])
      setBenchmarks(benchData || [])
      setVersions(verData || [])
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  // ── Registry Tab ──────────────────────────────────────────────────────────
  const openEdit = (m) => {
    setForm({ display_name: m.display_name, version: m.version, model_url: m.model_url || '', description: m.description || '', is_active: m.is_active ?? true, accuracy_top1: m.accuracy_top1 || '', sha256_checksum: m.sha256_checksum || '' })
    setEditModal(m)
  }

  const saveModel = async () => {
    setSaving(true)
    const { error } = await supabase.from('model_registry').update({
      display_name: form.display_name,
      version: form.version,
      model_url: form.model_url,
      description: form.description,
      is_active: form.is_active,
      accuracy_top1: form.accuracy_top1 || null,
      sha256_checksum: form.sha256_checksum || null,
      updated_at: new Date().toISOString(),
    }).eq('id', editModal.id)
    setSaving(false)
    if (!error) { setEditModal(null); loadModels(); logAudit(supabase, 'model_updated', 'model', editModal.id, { leaf_type: editModal.leaf_type, version: form.version }) }
    else alert('Save failed: ' + error.message)
  }

  const quickValidate = async (m) => {
    setValidating(v => ({ ...v, [m.id]: true }))
    setValidateResult(r => ({ ...r, [m.id]: null }))
    try {
      const issues = []
      if (!m.model_url) issues.push('No model URL configured')
      else {
        try {
          const res = await fetch(m.model_url, { method: 'HEAD', signal: AbortSignal.timeout(6000) })
          if (!res.ok) issues.push(`Model URL returned HTTP ${res.status}`)
          else {
            const size = res.headers.get('content-length')
            if (size && parseInt(size) < 1024) issues.push('Model file seems too small (< 1 KB)')
          }
        } catch { issues.push('Model URL unreachable or CORS blocked') }
      }
      if (!m.sha256_checksum) issues.push('No SHA-256 checksum recorded')
      if (!m.class_labels?.length) issues.push('No class labels configured')
      if (!m.accuracy_top1) issues.push('No accuracy metric recorded')
      if (!m.num_classes) issues.push('Number of classes not set')
      // Check if benchmarks exist
      const hasBench = benchmarks.some(b => b.leaf_type === m.leaf_type && b.version === m.version)
      if (!hasBench) issues.push('No benchmark evaluation results')
      setValidateResult(r => ({ ...r, [m.id]: { ok: issues.length === 0, issues } }))
    } finally {
      setValidating(v => ({ ...v, [m.id]: false }))
    }
  }

  const toggleActive = async (m) => {
    setConfirmAction({
      title: m.is_active !== false ? 'Deactivate Model' : 'Activate Model',
      message: m.is_active !== false
        ? `Deactivate "${m.display_name || m.leaf_type}"? This will stop serving this model to mobile users via OTA.`
        : `Reactivate "${m.display_name || m.leaf_type}"? It will become available for OTA again.`,
      danger: m.is_active !== false,
      confirmLabel: m.is_active !== false ? 'Deactivate' : 'Activate',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error } = await supabase.from('model_registry').update({ is_active: !m.is_active, updated_at: new Date().toISOString() }).eq('id', m.id)
        if (!error) { loadModels(); logAudit(supabase, m.is_active !== false ? 'model_deactivated' : 'model_activated', 'model', m.id, { leaf_type: m.leaf_type }) }
        else alert(error.message)
      }
    })
  }

  const deleteModel = async (m) => {
    setConfirmAction({
      title: 'Delete Model',
      message: `Permanently delete "${m.display_name || m.leaf_type}" v${m.version}? This will remove the model file from storage and the registry entry. This cannot be undone.`,
      danger: true,
      confirmLabel: 'Delete Permanently',
      onConfirm: async () => {
        setConfirmAction(null)
        try {
          if (m.model_url?.includes('supabase.co/storage')) {
            const match = m.model_url.match(/\/storage\/v1\/object\/public\/models\/(.+)/)
            if (match) await supabase.storage.from('models').remove([decodeURIComponent(match[1])])
          }
          const { error } = await supabase.from('model_registry').delete().eq('id', m.id)
          if (error) throw new Error(error.message)
          loadModels()
          logAudit(supabase, 'model_deleted', 'model', m.id, { leaf_type: m.leaf_type, version: m.version })
        } catch (err) { alert('Delete failed: ' + err.message) }
      }
    })
  }

  // ── Upload Tab ─────────────────────────────────────────────────────────────
  const handleUpload = async (e) => {
    e.preventDefault()
    if (!uploadFile) { setUploadMsg({ type: 'error', text: 'Please select a model file.' }); return }
    const { leaf_type, display_name, version, description, num_classes, class_labels_raw, is_new_leaf } = uploadForm
    if (!leaf_type || !version) { setUploadMsg({ type: 'error', text: 'Leaf type and version are required.' }); return }

    setUploading(true); setUploadProgress(10); setUploadMsg(null)
    try {
      // 1. Archive current model if exists
      const existing = models.find(m => m.leaf_type === leaf_type)
      if (existing) {
        await supabase.from('model_versions').upsert({
          leaf_type: existing.leaf_type,
          version: existing.version,
          display_name: existing.display_name,
          model_url: existing.model_url,
          sha256_checksum: existing.sha256_checksum,
          accuracy: existing.accuracy_top1,
          size_mb: uploadFile ? null : null,
        }, { onConflict: 'leaf_type,version' })
      }
      setUploadProgress(15)

      // 2. Upload .pth checkpoint to Supabase Storage
      await ensureBucket(supabase, 'models')
      setUploadProgress(20)

      const ext = uploadFile.name.split('.').pop()
      const storagePath = `${leaf_type}/v${version}/${leaf_type}_v${version}_checkpoint.${ext}`
      setUploadProgress(40)

      const publicUrl = await uploadToStorage(supabase, 'models', storagePath, uploadFile)
      setUploadProgress(70)

      // 3. Parse class labels
      const classLabels = class_labels_raw
        ? class_labels_raw.split('\n').map(l => l.trim()).filter(Boolean)
        : []

      // 4. Register as INACTIVE candidate (not auto-activated)
      const payload = {
        leaf_type,
        display_name: display_name || leaf_type,
        version,
        model_url: null, // will be set by pipeline after conversion
        sha256_checksum: null, // will be set by pipeline after conversion
        description: description || null,
        accuracy_top1: null, // will be computed by pipeline
        num_classes: num_classes ? parseInt(num_classes) : (classLabels.length || null),
        class_labels: classLabels.length ? classLabels : null,
        is_active: false, // inactive until admin reviews benchmarks
        updated_at: new Date().toISOString(),
      }

      const { error } = await supabase.from('model_registry').upsert(payload, { onConflict: 'leaf_type' })
      setUploadProgress(80)
      if (error) throw new Error(error.message)

      logAudit(supabase, 'model_uploaded', 'model', leaf_type, { version, display_name: display_name || leaf_type })

      // 5. Auto-trigger full pipeline (convert + validate + evaluate)
      let pipelineMsg = ''
      try {
        const { ghToken } = getGitHubConfig()
        if (ghToken) {
          await triggerGitHubWorkflow('model-pipeline.yml', { leaf_type, version, model_url: publicUrl })
          pipelineMsg = ' Full pipeline triggered (PTH → ONNX → TFLite → validate → evaluate). Results will appear in Benchmarks tab.'
          logAudit(supabase, 'pipeline_triggered', 'model', leaf_type, { version, workflow: 'model-pipeline.yml' })
        } else {
          pipelineMsg = ' Configure GitHub in Settings to auto-trigger the pipeline.'
        }
      } catch (pipeErr) {
        pipelineMsg = ` Pipeline trigger failed: ${pipeErr.message}`
      }

      setUploadProgress(100)
      setUploadMsg({ type: 'success', text: `Checkpoint "${display_name || leaf_type}" v${version} uploaded. Pipeline will convert to ONNX + TFLite, validate, and evaluate.${pipelineMsg}` })
      setUploadFile(null)
      if (fileInputRef.current) fileInputRef.current.value = ''
      loadModels()
    } catch (err) {
      setUploadMsg({ type: 'error', text: err.message })
    } finally {
      setUploading(false)
      setUploadProgress(0)
    }
  }

  // ── Validate Tab (GitHub Actions) ─────────────────────────────────────────
  const loadGhRuns = async () => {
    const data = await getGitHubWorkflowRuns('model-pipeline.yml')
    setGhRuns(data)
  }

  const runValidation = async () => {
    if (!valTarget) { setValMsg({ type: 'error', text: 'Select a model first.' }); return }
    setValRunning(true); setValMsg(null)
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations.')
      const targetModel = models.find(m => m.leaf_type === valTarget)
      await triggerGitHubWorkflow('model-pipeline.yml', { leaf_type: valTarget, version: targetModel?.version || '1.0.0', model_url: targetModel?.model_url || '' })
      setValMsg({ type: 'success', text: `Pipeline dispatched for "${valTarget}". Includes convert + validation + full evaluation. Check Benchmarks tab for results.` })
      logAudit(supabase, 'pipeline_triggered', 'model', valTarget, { workflow: 'model-pipeline.yml' })
      setTimeout(loadGhRuns, 3000)
    } catch (err) {
      setValMsg({ type: 'error', text: err.message })
    } finally {
      setValRunning(false)
    }
  }

  // ── Benchmarks helpers ────────────────────────────────────────────────────
  const getBenchmarksForModel = (leafType, version) =>
    benchmarks.filter(b => b.leaf_type === leafType && b.version === version)

  const getVersionsForLeaf = (leafType) =>
    versions.filter(v => v.leaf_type === leafType)

  const accuracyChartData = models.filter(m => m.accuracy_top1).map(m => ({ name: m.display_name || m.leaf_type, accuracy: parseFloat(m.accuracy_top1) }))

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading models…</span></div>

  return (
    <>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h1 className="page-title">Model Registry</h1>
          <p className="page-subtitle">Manage, upload, and validate leaf disease detection models (OTA)</p>
        </div>
        <button className="btn btn-primary" onClick={() => setTab('Upload Model')}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 4v12m-6-6l6-6 6 6M4 16v2a2 2 0 002 2h12a2 2 0 002-2v-2"/></svg>
          Upload Model
        </button>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {TABS.map(t => (
          <button key={t} onClick={() => setTab(t)} style={{ padding: '10px 18px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: tab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${tab === t ? '#16a34a' : 'transparent'}`, transition: 'all 0.15s', fontFamily: 'inherit' }}>
            {t}
          </button>
        ))}
      </div>

      {/* ── Registry Tab ── */}
      {tab === 'Registry' && (
        <>
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Registry</div><div className="card-title">All Models ({models.length})</div></div>
            </div>
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Leaf Type</th><th>Display Name</th><th>Version</th><th>Classes</th><th>Accuracy</th><th>Status</th><th>Updated</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {models.map(m => (
                    <Fragment key={m.id}>
                      <tr>
                        <td><strong style={{ color: '#121c28' }}>{m.leaf_type}</strong></td>
                        <td><div>{m.display_name}</div>{m.description && <div style={{ fontSize: 11, color: '#94a3b8' }}>{m.description}</div>}</td>
                        <td><span className="badge badge-primary">v{m.version}</span></td>
                        <td>{m.num_classes || '—'}</td>
                        <td>
                          {m.accuracy_top1
                            ? <span className={`badge ${parseFloat(m.accuracy_top1) >= 95 ? 'badge-green' : parseFloat(m.accuracy_top1) >= 85 ? 'badge-yellow' : 'badge-red'}`}>{m.accuracy_top1}%</span>
                            : <span style={{ color: '#94a3b8' }}>—</span>}
                        </td>
                        <td>
                          <span className={`badge ${m.is_active !== false ? 'badge-green' : 'badge-gray'}`}>
                            <span className={`status-dot ${m.is_active !== false ? 'green' : 'gray'}`} />
                            {m.is_active !== false ? 'Active' : 'Inactive'}
                          </span>
                        </td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{new Date(m.updated_at).toLocaleDateString()}</td>
                        <td>
                          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
                            <button className="btn btn-sm" onClick={() => openEdit(m)}>Edit</button>
                            <button className="btn btn-sm" onClick={() => quickValidate(m)} disabled={validating[m.id]}>
                              {validating[m.id] ? '…' : 'Quick Check'}
                            </button>
                            <button className="btn btn-sm" onClick={() => { setValTarget(m.leaf_type); setTab('Validate') }}>
                              Deep Validate
                            </button>
                            <button className="btn btn-sm" onClick={() => setExpandedId(expandedId === m.id ? null : m.id)}>
                              {expandedId === m.id ? 'Hide' : 'Labels'}
                            </button>
                            <button className={`btn btn-sm ${m.is_active !== false ? 'btn-danger' : ''}`} onClick={() => toggleActive(m)}>
                              {m.is_active !== false ? 'Deactivate' : 'Activate'}
                            </button>
                            <button className="btn btn-sm btn-danger" onClick={() => deleteModel(m)}>Delete</button>
                          </div>
                        </td>
                      </tr>
                      {validateResult[m.id] && (
                        <tr key={`vr-${m.id}`}>
                          <td colSpan={8} style={{ padding: '8px 12px 12px' }}>
                            <div className={`alert ${validateResult[m.id].ok ? 'alert-success' : 'alert-warn'}`}>
                              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
                                {validateResult[m.id].ok ? <path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/> : <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>}
                              </svg>
                              <div>
                                {validateResult[m.id].ok
                                  ? 'All quick checks passed — model URL reachable, metadata complete, benchmarks available.'
                                  : validateResult[m.id].issues.map((iss, i) => <div key={i}>⚠ {iss}</div>)}
                              </div>
                            </div>
                          </td>
                        </tr>
                      )}
                      {expandedId === m.id && (
                        <tr key={`cl-${m.id}`}>
                          <td colSpan={8} style={{ padding: '4px 12px 14px' }}>
                            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 8 }}>
                              {(Array.isArray(m.class_labels) ? m.class_labels : []).map((label, i) => (
                                <span key={i} className={`chip ${label.toLowerCase().includes('healthy') ? 'chip-green' : ''}`}>
                                  <span style={{ color: '#94a3b8', fontSize: 10 }}>{i}</span> {label.replace(/_/g, ' ')}
                                </span>
                              ))}
                              {!m.class_labels?.length && <span className="text-muted">No class labels configured</span>}
                            </div>
                            {m.model_url && (
                              <div style={{ fontSize: 12, marginBottom: 4 }}>
                                <span style={{ color: '#94a3b8' }}>Model URL: </span>
                                <a href={m.model_url} target="_blank" rel="noopener noreferrer" style={{ color: '#16a34a', wordBreak: 'break-all' }}>{m.model_url}</a>
                              </div>
                            )}
                            {m.sha256_checksum && (
                              <div style={{ fontSize: 12, marginBottom: 8 }}>
                                <span style={{ color: '#94a3b8' }}>SHA-256: </span>
                                <span className="font-mono" style={{ color: '#3d4f62' }}>{m.sha256_checksum}</span>
                              </div>
                            )}
                            {/* Version History */}
                            {getVersionsForLeaf(m.leaf_type).length > 0 && (
                              <>
                                <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 4, marginTop: 4 }}>Version History</div>
                                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                                  {getVersionsForLeaf(m.leaf_type).map(v => (
                                    <div key={v.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, padding: '4px 8px', background: 'rgba(0,0,0,0.02)', borderRadius: 6 }}>
                                      <span className="badge badge-gray">v{v.version}</span>
                                      <span style={{ color: '#64748b' }}>{v.display_name}</span>
                                      {v.accuracy && <span className="badge badge-yellow">{v.accuracy}%</span>}
                                      <span style={{ color: '#94a3b8', marginLeft: 'auto' }}>Archived {new Date(v.archived_at).toLocaleDateString()}</span>
                                    </div>
                                  ))}
                                </div>
                              </>
                            )}
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  ))}
                  {models.length === 0 && <tr><td colSpan={8} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>No models registered yet. Upload your first model.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {/* ── Benchmarks Tab ── */}
      {tab === 'Benchmarks' && (
        <>
          {/* Accuracy comparison chart */}
          {accuracyChartData.length > 0 && (
            <div className="card" style={{ marginBottom: 20 }}>
              <div className="card-header"><div><div className="card-label">Accuracy Comparison</div><div className="card-title">Model Accuracy</div></div></div>
              <ResponsiveContainer width="100%" height={200}>
                <BarChart data={accuracyChartData} margin={{ top: 0, right: 16, left: -20, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(0,0,0,0.05)" />
                  <XAxis dataKey="name" tick={{ fontSize: 11, fill: '#64748b' }} axisLine={false} tickLine={false} />
                  <YAxis domain={[80, 100]} tick={{ fontSize: 11, fill: '#94a3b8' }} axisLine={false} tickLine={false} unit="%" />
                  <Tooltip content={<CustomTooltip />} />
                  <Bar dataKey="accuracy" name="Accuracy" radius={[4, 4, 0, 0]} unit="%">
                    {accuracyChartData.map((_, i) => <Cell key={i} fill={i % 2 === 0 ? '#16a34a' : '#0284c7'} />)}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}

          {/* Per-model benchmark details */}
          {models.map(m => {
            const modelBench = getBenchmarksForModel(m.leaf_type, m.version)
            if (!modelBench.length) return (
              <div key={m.id} className="card" style={{ marginBottom: 16 }}>
                <div className="card-header">
                  <div>
                    <div className="card-label">{m.display_name || m.leaf_type}</div>
                    <div className="card-title">v{m.version} — No Benchmark Data</div>
                  </div>
                  <button className="btn btn-sm" onClick={() => { setValTarget(m.leaf_type); setTab('Validate') }}>Run Pipeline</button>
                </div>
                <p style={{ fontSize: 13, color: '#94a3b8', padding: '0 0 8px' }}>
                  No evaluation results yet. Run the pipeline from the Validate tab to generate benchmarks.
                </p>
              </div>
            )

            const tflite = modelBench.find(b => b.format === 'tflite')
            const pytorch = modelBench.find(b => b.format === 'pytorch')
            const onnx = modelBench.find(b => b.format === 'onnx')
            const formats = [pytorch, onnx, tflite].filter(Boolean)

            return (
              <div key={m.id} className="card" style={{ marginBottom: 20 }}>
                <div className="card-header">
                  <div>
                    <div className="card-label">{m.display_name || m.leaf_type}</div>
                    <div className="card-title">v{m.version} — Full Benchmark Results</div>
                  </div>
                  <span className={`badge ${m.is_active !== false ? 'badge-green' : 'badge-gray'}`}>
                    {m.is_active !== false ? 'Active' : 'Candidate'}
                  </span>
                </div>

                {/* Summary metrics cards */}
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
                  {[
                    { label: 'Accuracy', value: tflite?.accuracy != null ? `${tflite.accuracy.toFixed(1)}%` : '—', color: '#16a34a' },
                    { label: 'F1 Score', value: tflite?.f1_macro != null ? tflite.f1_macro.toFixed(4) : '—', color: '#0284c7' },
                    { label: 'Latency', value: tflite?.latency_mean_ms != null ? `${tflite.latency_mean_ms.toFixed(1)} ms` : '—', color: '#7c3aed' },
                    { label: 'Model Size', value: tflite?.size_mb != null ? `${tflite.size_mb.toFixed(2)} MB` : '—', color: '#ca8a04' },
                  ].map(s => (
                    <div key={s.label} style={{ padding: '10px 14px', borderRadius: 10, border: '1px solid rgba(0,0,0,0.06)', position: 'relative', overflow: 'hidden' }}>
                      <div style={{ position: 'absolute', top: 0, left: 0, width: 3, height: '100%', background: s.color }} />
                      <div style={{ fontSize: 11, color: '#94a3b8', fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.05em' }}>{s.label}</div>
                      <div style={{ fontSize: 18, fontWeight: 700, color: '#121c28', marginTop: 2 }}>{s.value}</div>
                    </div>
                  ))}
                </div>

                {/* Format comparison table */}
                <div style={{ marginBottom: 16 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 6 }}>Format Comparison</div>
                  <div className="table-wrapper">
                    <table>
                      <thead>
                        <tr>
                          <th>Format</th><th>Accuracy</th><th>Precision</th><th>Recall</th><th>F1</th>
                          <th>Latency</th><th>P99</th><th>FPS</th><th>Size</th><th>Memory</th><th>KL Div</th>
                        </tr>
                      </thead>
                      <tbody>
                        {formats.map(b => (
                          <tr key={b.format}>
                            <td><strong style={{ textTransform: 'capitalize' }}>{b.format}</strong></td>
                            <td>{b.accuracy != null ? <span className={`badge ${b.accuracy >= 85 ? 'badge-green' : 'badge-yellow'}`}>{b.accuracy.toFixed(1)}%</span> : '—'}</td>
                            <td>{b.precision_macro != null ? b.precision_macro.toFixed(4) : '—'}</td>
                            <td>{b.recall_macro != null ? b.recall_macro.toFixed(4) : '—'}</td>
                            <td>{b.f1_macro != null ? b.f1_macro.toFixed(4) : '—'}</td>
                            <td>{b.latency_mean_ms != null ? `${b.latency_mean_ms.toFixed(1)} ms` : '—'}</td>
                            <td>{b.latency_p99_ms != null ? `${b.latency_p99_ms.toFixed(1)} ms` : '—'}</td>
                            <td>{b.fps != null ? b.fps.toFixed(0) : '—'}</td>
                            <td>{b.size_mb != null ? `${b.size_mb.toFixed(2)} MB` : '—'}</td>
                            <td>{b.memory_mb != null ? `${b.memory_mb.toFixed(1)} MB` : '—'}</td>
                            <td className="font-mono" style={{ fontSize: 11 }}>{b.kl_divergence != null ? b.kl_divergence.toFixed(6) : '—'}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>

                {/* Per-class metrics (from TFLite — the deployment format) */}
                {tflite?.per_class_metrics?.length > 0 && (
                  <div>
                    <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 6 }}>Per-Class Metrics (TFLite)</div>
                    <div className="table-wrapper">
                      <table>
                        <thead>
                          <tr><th>Class</th><th>Precision</th><th>Recall</th><th>F1-Score</th><th>Support</th></tr>
                        </thead>
                        <tbody>
                          {tflite.per_class_metrics.map((c, i) => (
                            <tr key={i}>
                              <td style={{ fontWeight: 500 }}>{c.class?.replace(/_/g, ' ')}</td>
                              <td>{c.precision?.toFixed(4)}</td>
                              <td>{c.recall?.toFixed(4)}</td>
                              <td>
                                <span className={`badge ${c.f1 >= 0.9 ? 'badge-green' : c.f1 >= 0.7 ? 'badge-yellow' : 'badge-red'}`}>
                                  {c.f1?.toFixed(4)}
                                </span>
                              </td>
                              <td style={{ color: '#94a3b8' }}>{c.support}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                )}

                {/* Model complexity info */}
                {pytorch && (pytorch.flops_m != null || pytorch.params_m != null) && (
                  <div style={{ marginTop: 12, fontSize: 12, color: '#64748b', display: 'flex', gap: 16 }}>
                    {pytorch.params_m != null && <span>Parameters: <strong>{pytorch.params_m.toFixed(2)} M</strong></span>}
                    {pytorch.flops_m != null && <span>FLOPs: <strong>{pytorch.flops_m.toFixed(1)} M</strong></span>}
                  </div>
                )}
              </div>
            )
          })}

          {models.length === 0 && (
            <div className="card" style={{ textAlign: 'center', padding: 40, color: '#94a3b8' }}>
              No models registered. Upload a model to see benchmarks.
            </div>
          )}
        </>
      )}

      {/* ── Upload Model Tab ── */}
      {tab === 'Upload Model' && (
        <div className="card" style={{ maxWidth: 640 }}>
          <div className="card-header">
            <div><div className="card-label">OTA Upload</div><div className="card-title">Register New or Updated Model</div></div>
          </div>
          <div className="alert alert-info" style={{ marginBottom: 16 }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
            <div>
              Upload a <strong>.pth</strong> PyTorch checkpoint. The pipeline will automatically:
              <br />1. Convert to <strong>ONNX</strong> and <strong>TFLite</strong> formats
              <br />2. Validate cross-format consistency (PyTorch vs ONNX vs TFLite)
              <br />3. Run full evaluation (accuracy, precision, recall, F1, latency, etc.)
              <br />4. Upload the converted <strong>.tflite</strong> to Supabase Storage for OTA
              <br />The model starts as <strong>inactive</strong> — review benchmarks before activating.
            </div>
          </div>

          <form onSubmit={handleUpload}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0 16px' }}>
              <div className="form-group">
                <label className="form-label">Leaf Type *</label>
                {uploadForm.is_new_leaf
                  ? <input className="form-input" placeholder="e.g. corn, pepper, mango" value={uploadForm.leaf_type} onChange={e => setUploadForm(f => ({ ...f, leaf_type: e.target.value }))} required />
                  : (
                    <select className="form-input" value={uploadForm.leaf_type} onChange={e => setUploadForm(f => ({ ...f, leaf_type: e.target.value }))}>
                      <option value="">Select existing leaf type…</option>
                      {models.map(m => <option key={m.leaf_type} value={m.leaf_type}>{m.display_name} ({m.leaf_type})</option>)}
                    </select>
                  )
                }
                <label style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 6, fontSize: 12, color: '#64748b', cursor: 'pointer' }}>
                  <input type="checkbox" checked={uploadForm.is_new_leaf} onChange={e => setUploadForm(f => ({ ...f, is_new_leaf: e.target.checked, leaf_type: '' }))} />
                  Add new leaf type
                </label>
              </div>

              <div className="form-group">
                <label className="form-label">Version *</label>
                <input className="form-input" value={uploadForm.version} onChange={e => setUploadForm(f => ({ ...f, version: e.target.value }))} placeholder="1.0.0" required />
              </div>

              <div className="form-group">
                <label className="form-label">Display Name</label>
                <input className="form-input" value={uploadForm.display_name} onChange={e => setUploadForm(f => ({ ...f, display_name: e.target.value }))} placeholder="e.g. Tomato Disease Detector" />
              </div>

              <div className="form-group">
                <label className="form-label">Number of Classes</label>
                <input className="form-input" type="number" min="2" value={uploadForm.num_classes} onChange={e => setUploadForm(f => ({ ...f, num_classes: e.target.value }))} placeholder="Auto-detected from labels" />
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Description</label>
              <input className="form-input" value={uploadForm.description} onChange={e => setUploadForm(f => ({ ...f, description: e.target.value }))} placeholder="Optional notes about this model version" />
            </div>

            <div className="form-group">
              <label className="form-label">Class Labels (one per line)</label>
              <textarea
                className="form-input"
                rows={5}
                value={uploadForm.class_labels_raw}
                onChange={e => setUploadForm(f => ({ ...f, class_labels_raw: e.target.value }))}
                placeholder={"Tomato___Bacterial_spot\nTomato___Early_blight\nTomato___healthy\n..."}
                style={{ resize: 'vertical', fontFamily: 'monospace', fontSize: 12 }}
              />
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 3 }}>Format: one label per line, e.g. PlantType___Disease_Name</div>
            </div>

            <div className="form-group">
              <label className="form-label">Model Checkpoint (.pth) *</label>
              <input ref={fileInputRef} type="file" accept=".pth,.pt,.bin" className="form-input" onChange={e => setUploadFile(e.target.files[0])} style={{ padding: '7px 10px' }} />
              {uploadFile && (
                <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>
                  Selected: <strong>{uploadFile.name}</strong> ({formatBytes(uploadFile.size)})
                </div>
              )}
            </div>

            {/* SHA-256 will be computed by pipeline for the converted .tflite */}
            {uploadFile && (
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4, fontStyle: 'italic' }}>
                SHA-256 checksum will be computed automatically for the converted .tflite file by the pipeline.
              </div>
            )}

            <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 8, padding: '10px 14px', marginBottom: 16, fontSize: 12, color: '#166534' }}>
              <strong>Full Pipeline:</strong> .pth → ONNX → TFLite → cross-format validation → full evaluation (accuracy, precision, recall, F1, latency, FPS, memory, model size, KL divergence). The converted <strong>.tflite</strong> and SHA-256 checksum will be set automatically. Model starts as <strong>inactive</strong> — review benchmarks before activating.
            </div>

            {uploading && (
              <div style={{ marginBottom: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: '#64748b', marginBottom: 4 }}>
                  <span>Uploading to Supabase Storage…</span><span>{uploadProgress}%</span>
                </div>
                <div className="progress-track"><div className="progress-fill" style={{ width: `${uploadProgress}%` }} /></div>
              </div>
            )}

            {uploadMsg && (
              <div className={`alert ${uploadMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div style={{ wordBreak: 'break-all' }}>{uploadMsg.text}</div>
              </div>
            )}

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button type="button" className="btn" onClick={() => { setUploadFile(null); setUploadMsg(null); if (fileInputRef.current) fileInputRef.current.value = '' }}>Clear</button>
              <button type="submit" className="btn btn-primary" disabled={uploading}>
                {uploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Uploading…</> : 'Upload & Register'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ── Validate Tab ── */}
      {tab === 'Validate' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Model Pipeline</div><div className="card-title">Validate & Evaluate</div></div>
            </div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 12 }}>
              Triggers the full model pipeline via GitHub Actions:
            </p>
            <div style={{ fontSize: 13, color: '#3d4f62', marginBottom: 16, padding: '10px 14px', background: '#f8fafc', borderRadius: 8, lineHeight: 1.8 }}>
              <strong>1. Format conversion</strong> — Converts .pth checkpoint to ONNX (opset 17) and TFLite (via onnx2tf).<br />
              <strong>2. Cross-format validation</strong> — Checks ONNX and TFLite produce consistent outputs vs PyTorch (tolerance: 1e-4, using 5 random inputs).<br />
              <strong>3. Full evaluation</strong> — Runs all 3 formats on the real test dataset (15% stratified split). Measures accuracy, precision, recall, F1, latency, FPS, memory, model size, KL divergence.<br />
              <strong>4. Upload results</strong> — Uploads converted .tflite to Supabase Storage, writes metrics to database. View in Benchmarks tab.
            </div>

            <div className="form-group">
              <label className="form-label">Model to Validate</label>
              <select className="form-input" value={valTarget} onChange={e => setValTarget(e.target.value)}>
                <option value="">Select model…</option>
                {models.map(m => <option key={m.leaf_type} value={m.leaf_type}>{m.display_name || m.leaf_type} (v{m.version})</option>)}
              </select>
            </div>

            <div className="alert alert-info" style={{ marginBottom: 12 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Dispatches <code>model-pipeline.yml</code> workflow. Requires GitHub token in <strong>Settings → Integrations</strong>. Results appear in Benchmarks tab after ~5-10 minutes.</div>
            </div>

            {valMsg && (
              <div className={`alert ${valMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div>{valMsg.text}</div>
              </div>
            )}

            <button className="btn btn-primary" onClick={runValidation} disabled={valRunning || !valTarget}>
              {valRunning ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Running…</> : 'Run Pipeline'}
            </button>
          </div>

          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Recent Runs</div><div className="card-title">Pipeline Workflow History</div></div>
              <button className="btn btn-sm" onClick={loadGhRuns}>Refresh</button>
            </div>
            {ghRuns === null && (
              <div className="alert alert-warn">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
                <div>GitHub not configured. <strong>Settings → Integrations</strong> to add your token.</div>
              </div>
            )}
            {ghRuns && ghRuns.workflow_runs?.length === 0 && <p style={{ fontSize: 13, color: '#94a3b8' }}>No runs yet. Trigger a pipeline to see history here.</p>}
            {ghRuns?.workflow_runs?.map(run => (
              <div key={run.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <div>
                  <span className={`status-dot ${run.conclusion === 'success' ? 'green' : run.status === 'in_progress' ? 'yellow' : 'red'}`} style={{ marginRight: 8 }} />
                  <a href={run.html_url} target="_blank" rel="noopener noreferrer" style={{ color: '#121c28', textDecoration: 'none', fontWeight: 500 }}>Run #{run.run_number}</a>
                  <span style={{ color: '#94a3b8', marginLeft: 8 }}>{run.head_commit?.message?.slice(0, 40)}</span>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <span className={`badge ${run.conclusion === 'success' ? 'badge-green' : run.status === 'in_progress' ? 'badge-yellow' : 'badge-red'}`}>{run.status === 'in_progress' ? 'Running' : run.conclusion || run.status}</span>
                  <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 2 }}>{new Date(run.created_at).toLocaleString()}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── OTA Deploy Tab ── */}
      {tab === 'OTA Deploy' && (
        <div className="card">
          <div className="card-header">
            <div><div className="card-label">Over-The-Air</div><div className="card-title">OTA Model Deployment</div></div>
          </div>

          {/* What is OTA explanation */}
          <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 10, padding: '14px 18px', marginBottom: 20 }}>
            <div style={{ fontWeight: 700, fontSize: 14, color: '#166534', marginBottom: 6 }}>What is OTA?</div>
            <p style={{ fontSize: 13, color: '#166534', margin: 0, lineHeight: 1.6 }}>
              OTA (Over-The-Air) allows updating the AI model on users' phones <strong>without</strong> requiring a new app version from the Play Store.
              When you activate a model here, the mobile app automatically detects and downloads it on next launch.
            </p>
          </div>

          {/* OTA flow */}
          <div style={{ background: '#f8fafc', border: '1px solid rgba(0,0,0,0.06)', borderRadius: 10, padding: '14px 18px', marginBottom: 20, fontSize: 12, fontFamily: 'monospace', lineHeight: 2, color: '#3d4f62' }}>
            <div style={{ fontWeight: 700, fontSize: 12, fontFamily: 'inherit', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em', color: '#94a3b8' }}>Deployment Flow</div>
            Admin uploads model → <strong>Supabase Storage</strong><br />
            Admin activates model → <code>model_registry.is_active = true</code><br />
            User opens app → app queries <code>model_registry</code><br />
            App detects new version → downloads <code>.tflite</code> from <code>model_url</code><br />
            App verifies SHA-256 → loads new model
          </div>

          {/* Deployment status table */}
          <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 8 }}>Deployment Status</div>
          <table>
            <thead>
              <tr><th>Leaf Type</th><th>Version</th><th>Model URL</th><th>SHA-256</th><th>Benchmarked</th><th>Status</th><th>OTA</th></tr>
            </thead>
            <tbody>
              {models.map(m => {
                const hasBench = benchmarks.some(b => b.leaf_type === m.leaf_type && b.version === m.version)
                const hasUrl = !!m.model_url
                const hasHash = !!m.sha256_checksum
                const isActive = m.is_active !== false
                const allGood = hasUrl && hasHash && hasBench && isActive
                return (
                  <tr key={m.id}>
                    <td><strong style={{ color: '#121c28' }}>{m.leaf_type}</strong></td>
                    <td><span className="badge badge-primary">v{m.version}</span></td>
                    <td>{hasUrl ? <span className="badge badge-green" style={{ fontSize: 10 }}>Uploaded</span> : <span className="badge badge-red" style={{ fontSize: 10 }}>Missing</span>}</td>
                    <td>{hasHash ? <span className="badge badge-green" style={{ fontSize: 10 }}>Recorded</span> : <span className="badge badge-red" style={{ fontSize: 10 }}>Missing</span>}</td>
                    <td>{hasBench ? <span className="badge badge-green" style={{ fontSize: 10 }}>Complete</span> : <span className="badge badge-yellow" style={{ fontSize: 10 }}>Pending</span>}</td>
                    <td><span className={`badge ${isActive ? 'badge-green' : 'badge-gray'}`}>{isActive ? 'Active' : 'Inactive'}</span></td>
                    <td>
                      <span className={`badge ${allGood ? 'badge-green' : 'badge-red'}`}>
                        {allGood ? 'Live' : 'Not ready'}
                      </span>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>

          {/* Checklist info */}
          <div style={{ marginTop: 16, fontSize: 12, color: '#64748b', lineHeight: 1.8 }}>
            <strong>Deployment checklist:</strong> A model is OTA-ready when all conditions are met:
            <br />1. Model file uploaded to Supabase Storage (model_url set)
            <br />2. SHA-256 checksum recorded (for integrity verification on device)
            <br />3. Benchmark evaluation completed (accuracy verified)
            <br />4. Model set to Active (is_active = true)
          </div>
        </div>
      )}

      {/* Edit Modal */}
      {editModal && (
        <div className="modal-overlay" onClick={() => setEditModal(null)}>
          <div className="modal" style={{ width: 520 }} onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">Edit — {editModal.leaf_type}</span>
              <button className="modal-close" onClick={() => setEditModal(null)}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M6 18L18 6M6 6l12 12"/></svg>
              </button>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0 16px' }}>
              <div className="form-group">
                <label className="form-label">Display Name</label>
                <input className="form-input" value={form.display_name} onChange={e => setForm(f => ({ ...f, display_name: e.target.value }))} />
              </div>
              <div className="form-group">
                <label className="form-label">Version</label>
                <input className="form-input" value={form.version} onChange={e => setForm(f => ({ ...f, version: e.target.value }))} />
              </div>
              <div className="form-group" style={{ gridColumn: '1/-1' }}>
                <label className="form-label">Model URL (override)</label>
                <input className="form-input" value={form.model_url} onChange={e => setForm(f => ({ ...f, model_url: e.target.value }))} placeholder="https://…" />
              </div>
              <div className="form-group">
                <label className="form-label">Accuracy (%)</label>
                <input className="form-input" type="number" value={form.accuracy_top1} onChange={e => setForm(f => ({ ...f, accuracy_top1: e.target.value }))} />
              </div>
              <div className="form-group">
                <label className="form-label">SHA-256 Checksum</label>
                <input className="form-input" value={form.sha256_checksum} onChange={e => setForm(f => ({ ...f, sha256_checksum: e.target.value }))} placeholder="hex hash…" style={{ fontFamily: 'monospace', fontSize: 12 }} />
              </div>
              <div className="form-group" style={{ gridColumn: '1/-1' }}>
                <label className="form-label">Description</label>
                <input className="form-input" value={form.description} onChange={e => setForm(f => ({ ...f, description: e.target.value }))} />
              </div>
            </div>
            <div className="form-group" style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <input type="checkbox" id="is_active" checked={form.is_active} onChange={e => setForm(f => ({ ...f, is_active: e.target.checked }))} style={{ accentColor: '#16a34a' }} />
              <label htmlFor="is_active" className="form-label" style={{ marginBottom: 0 }}>Active — served to mobile app via OTA</label>
            </div>
            <div className="modal-footer">
              <button className="btn" onClick={() => setEditModal(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveModel} disabled={saving}>{saving ? 'Saving…' : 'Save Changes'}</button>
            </div>
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}
