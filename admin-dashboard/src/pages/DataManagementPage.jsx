import { useState, useEffect, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { downloadFile, formatBytes, triggerGitHubWorkflow, getGitHubWorkflowRuns, getGitHubConfig, uploadToStorage, ensureBucket } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const DTABS = ['Overview', 'Upload Dataset', 'Import CSV', 'DVC Sync', 'Export', 'Storage Files']

export default function DataManagementPage() {
  const [dtab, setDtab] = useState('Overview')
  const [stats, setStats] = useState({ total: 0 })
  const [quality, setQuality] = useState([])
  const [loading, setLoading] = useState(true)
  const [leafOptions, setLeafOptions] = useState([])

  // DVC state
  const [dvcLog, setDvcLog] = useState([])
  const [dvcRunning, setDvcRunning] = useState(false)
  const [dvcRuns, setDvcRuns] = useState(null)

  // Dataset upload state
  const [dsLeafType, setDsLeafType] = useState('')
  const [dsFile, setDsFile] = useState(null)
  const [dsUploading, setDsUploading] = useState(false)
  const [dsProgress, setDsProgress] = useState(0)
  const [dsMsg, setDsMsg] = useState(null)
  const dsRef = useRef()

  // CSV import state
  const [csvFile, setCsvFile] = useState(null)
  const [csvParsed, setCsvParsed] = useState(null)
  const [csvImporting, setCsvImporting] = useState(false)
  const [csvProgress, setCsvProgress] = useState(0)
  const [csvMsg, setCsvMsg] = useState(null)
  const csvRef = useRef()

  // Storage Files state
  const [storedFiles, setStoredFiles] = useState([])
  const [storageLoading, setStorageLoading] = useState(false)
  const [confirmAction, setConfirmAction] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => { loadData() }, [])

  const loadData = async () => {
    setLoading(true)
    setError(null)
    try {
    const { data: rows } = await supabase.from('predictions').select('user_id, leaf_type, predicted_class_name, confidence, created_at').order('created_at', { ascending: false })
    if (rows) {
      const leafMap = {}
      rows.forEach(r => {
        leafMap[r.leaf_type] = (leafMap[r.leaf_type] || 0) + 1
      })
      setStats({ total: rows.length })
      setQuality(Object.entries(leafMap).map(([lt, total]) => {
        const ltRows = rows.filter(r => r.leaf_type === lt)
        return {
          name: lt, total,
          highConf: (ltRows.filter(r => r.confidence >= 0.8).length / total * 100).toFixed(0),
        }
      }))
      setLeafOptions(Object.keys(leafMap))
    }
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  // ── DVC via GitHub Actions ────────────────────────────────────────────────
  const runDvc = async (op) => {
    setDvcRunning(true); setDvcLog([])
    const ts = () => new Date().toLocaleTimeString()
    const { ghToken } = getGitHubConfig()
    try {
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations to add your token.')
      setDvcLog(l => [...l, `[${ts()}] Triggering DVC ${op} via GitHub Actions…`])
      const workflow = op === 'push' ? 'dvc-push.yml' : 'dvc-pull.yml'
      await triggerGitHubWorkflow(workflow)
      setDvcLog(l => [...l, `[${ts()}] ✓ Workflow dispatched. Checking status…`])
      await new Promise(r => setTimeout(r, 3000))
      const runs = await getGitHubWorkflowRuns(workflow)
      setDvcRuns(runs)
      const latest = runs?.workflow_runs?.[0]
      if (latest) setDvcLog(l => [...l, `[${ts()}] Latest run: #${latest.run_number} — ${latest.status}. View: ${latest.html_url}`])
    } catch (err) {
      setDvcLog(l => [...l, `[${ts()}] ✗ Error: ${err.message}`])
    } finally {
      setDvcRunning(false)
    }
  }

  const refreshDvcRuns = async () => {
    for (const wf of ['dvc-push.yml', 'dvc-pull.yml']) {
      const r = await getGitHubWorkflowRuns(wf)
      if (r?.workflow_runs?.length) { setDvcRuns(r); break }
    }
  }

  // ── Dataset file upload to Supabase Storage ──────────────────────────────
  const uploadDataset = async (e) => {
    e.preventDefault()
    if (!dsFile || !dsLeafType) { setDsMsg({ type: 'error', text: 'Select leaf type and file.' }); return }
    setDsUploading(true); setDsProgress(20); setDsMsg(null)
    try {
      await ensureBucket(supabase, 'datasets')
      setDsProgress(40)
      const path = `${dsLeafType}/${new Date().toISOString().slice(0, 10)}_${dsFile.name}`
      const publicUrl = await uploadToStorage(supabase, 'datasets', path, dsFile)
      setDsProgress(100)
      setDsMsg({ type: 'success', text: `✓ Uploaded "${dsFile.name}" (${formatBytes(dsFile.size)}) to datasets/${dsLeafType}/. URL: ${publicUrl}` })
      setDsFile(null); if (dsRef.current) dsRef.current.value = ''
    } catch (err) {
      setDsMsg({ type: 'error', text: err.message })
    } finally {
      setDsUploading(false); setDsProgress(0)
    }
  }

  // ── CSV Import into predictions table ─────────────────────────────────────
  const parseCSV = async (file) => {
    const text = await file.text()
    const lines = text.split('\n').filter(l => l.trim())
    if (lines.length < 2) { setCsvMsg({ type: 'error', text: 'CSV has no data rows.' }); return }
    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''))
    const rows = lines.slice(1).map(line => {
      const values = line.match(/(".*?"|[^,]+|(?<=,)(?=,)|^(?=,)|(?<=,)$)/g) || line.split(',')
      const row = {}
      headers.forEach((h, i) => { row[h] = (values[i] || '').trim().replace(/^"|"$/g, '') || null })
      return row
    }).filter(r => Object.values(r).some(v => v))
    setCsvParsed({ headers, rows: rows.slice(0, 10), total: rows.length, all: rows })
    setCsvMsg(null)
  }

  const importCSV = async () => {
    if (!csvParsed) return
    setCsvImporting(true); setCsvProgress(0); setCsvMsg(null)
    const BATCH = 100
    const { all } = csvParsed
    let imported = 0
    try {
      for (let i = 0; i < all.length; i += BATCH) {
        const batch = all.slice(i, i + BATCH)
        const { error } = await supabase.from('predictions').insert(batch)
        if (error) throw new Error(`Batch ${Math.floor(i / BATCH) + 1} failed: ${error.message}`)
        imported += batch.length
        setCsvProgress(Math.round(imported / all.length * 100))
      }
      setCsvMsg({ type: 'success', text: `✓ Imported ${imported.toLocaleString()} records successfully.` })
      setCsvParsed(null); setCsvFile(null); if (csvRef.current) csvRef.current.value = ''
      loadData()
    } catch (err) {
      setCsvMsg({ type: 'error', text: err.message })
    } finally {
      setCsvImporting(false)
    }
  }

  // ── Export ──────────────────────────────────────────────────────────────
  const exportAll = async (fmt) => {
    const { data } = await supabase.from('predictions').select('*').order('created_at', { ascending: false }).limit(50000)
    if (!data?.length) return
    const name = `agrikd-data-${new Date().toISOString().slice(0, 10)}`
    if (fmt === 'csv') {
      const h = Object.keys(data[0])
      downloadFile([h.join(','), ...data.map(r => h.map(k => JSON.stringify(r[k] ?? '')).join(','))].join('\n'), `${name}.csv`, 'text/csv')
    } else {
      downloadFile(JSON.stringify(data, null, 2), `${name}.json`, 'application/json')
    }
  }

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading data…</span></div>

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Data & DVC</h1>
        <p className="page-subtitle">Dataset management, quality metrics, cloud sync (DVC), and import/export</p>
      </div>

      {/* Tab nav */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {DTABS.map(t => (
          <button key={t} onClick={() => setDtab(t)} style={{ padding: '10px 16px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: dtab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${dtab === t ? '#16a34a' : 'transparent'}`, fontFamily: 'inherit' }}>
            {t}
          </button>
        ))}
      </div>

      {/* ── Overview Tab ── */}
      {dtab === 'Overview' && (
        <>
          <div className="stats-grid" style={{ marginBottom: 16 }}>
            {[
              { label: 'Total Records', value: stats.total.toLocaleString(), accent: '#16a34a' },
            ].map(s => (
              <div key={s.label} className="stat-card" style={{ padding: '14px 16px' }}>
                <div className="stat-card-accent" style={{ background: s.accent }} />
                <div className="stat-label">{s.label}</div>
                <div className="stat-value" style={{ fontSize: 22 }}>{s.value}</div>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">Quality Metrics</div><div className="card-title">Data Quality by Leaf Type</div></div></div>
            <table>
              <thead><tr><th>Leaf Type</th><th>Total Records</th><th>High Confidence (%)</th></tr></thead>
              <tbody>
                {quality.map(q => (
                  <tr key={q.name}>
                    <td><strong style={{ color: '#121c28' }}>{q.name}</strong></td>
                    <td>{q.total.toLocaleString()}</td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div className="progress-track" style={{ flex: 1 }}><div className="progress-fill" style={{ width: `${q.highConf}%` }} /></div>
                        <span style={{ fontSize: 12, color: '#64748b', minWidth: 30 }}>{q.highConf}%</span>
                      </div>
                    </td>
                  </tr>
                ))}
                {quality.length === 0 && <tr><td colSpan={3} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No data yet</td></tr>}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ── Upload Dataset Tab ── */}
      {dtab === 'Upload Dataset' && (
        <div style={{ maxWidth: 600 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">Storage</div><div className="card-title">Upload Dataset Files to Supabase Storage</div></div></div>
            <div className="alert alert-info" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Upload raw dataset files (images, ZIPs, CSVs) to Supabase Storage bucket <code>datasets</code>. Files are stored under <code>datasets/{'{leaf_type}'}/{'{date}'}_{'{filename}'}</code>. Use <strong>Import CSV</strong> tab to insert prediction records from a CSV into the database.</div>
            </div>
            <form onSubmit={uploadDataset}>
              <div className="form-group">
                <label className="form-label">Leaf Type *</label>
                <select className="form-input" value={dsLeafType} onChange={e => setDsLeafType(e.target.value)} required>
                  <option value="">Select leaf type…</option>
                  {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
                  <option value="__new__">+ New leaf type (type below)</option>
                </select>
                {dsLeafType === '__new__' && <input className="form-input" placeholder="Enter new leaf type name" onChange={e => setDsLeafType(e.target.value)} style={{ marginTop: 6 }} />}
              </div>
              <div className="form-group">
                <label className="form-label">File (image, ZIP, CSV, etc.)</label>
                <input ref={dsRef} type="file" className="form-input" style={{ padding: '7px 10px' }} onChange={e => setDsFile(e.target.files[0])} required />
                {dsFile && <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>{dsFile.name} — {formatBytes(dsFile.size)}</div>}
              </div>
              {dsUploading && (
                <div style={{ marginBottom: 12 }}>
                  <div className="progress-track"><div className="progress-fill" style={{ width: `${dsProgress}%` }} /></div>
                  <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>Uploading… {dsProgress}%</div>
                </div>
              )}
              {dsMsg && (
                <div className={`alert ${dsMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                  <div style={{ wordBreak: 'break-all' }}>{dsMsg.text}</div>
                </div>
              )}
              <button type="submit" className="btn btn-primary" disabled={dsUploading}>
                {dsUploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Uploading…</> : 'Upload to Storage'}
              </button>
            </form>
          </div>
        </div>
      )}

      {/* ── Import CSV Tab ── */}
      {dtab === 'Import CSV' && (
        <div style={{ maxWidth: 700 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">Database</div><div className="card-title">Import Predictions from CSV</div></div></div>
            <div className="alert alert-warn" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
              <div>CSV must have headers matching <code>predictions</code> table columns. Required: <code>leaf_type</code>, <code>predicted_class_name</code>, <code>confidence</code>. Optional: <code>user_id, notes, model_version, created_at</code>.</div>
            </div>
            <div className="form-group">
              <label className="form-label">CSV File</label>
              <input ref={csvRef} type="file" accept=".csv,text/csv" className="form-input" style={{ padding: '7px 10px' }} onChange={e => { setCsvFile(e.target.files[0]); setCsvParsed(null); setCsvMsg(null); if (e.target.files[0]) parseCSV(e.target.files[0]) }} />
            </div>

            {csvParsed && (
              <div style={{ marginBottom: 16 }}>
                <div className="alert alert-success" style={{ marginBottom: 10 }}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                  <div>Parsed <strong>{csvParsed.total.toLocaleString()}</strong> rows. Columns: {csvParsed.headers.join(', ')}</div>
                </div>
                <div style={{ overflowX: 'auto', border: '1px solid rgba(0,0,0,0.08)', borderRadius: 8 }}>
                  <table>
                    <thead><tr>{csvParsed.headers.map(h => <th key={h}>{h}</th>)}</tr></thead>
                    <tbody>
                      {csvParsed.rows.map((r, i) => <tr key={i}>{csvParsed.headers.map(h => <td key={h} style={{ maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12 }}>{r[h] ?? ''}</td>)}</tr>)}
                    </tbody>
                  </table>
                  {csvParsed.total > 10 && <div style={{ padding: '6px 12px', fontSize: 12, color: '#94a3b8', borderTop: '1px solid rgba(0,0,0,0.06)' }}>Showing first 10 of {csvParsed.total.toLocaleString()} rows</div>}
                </div>
              </div>
            )}

            {csvImporting && (
              <div style={{ marginBottom: 12 }}>
                <div className="progress-track"><div className="progress-fill" style={{ width: `${csvProgress}%` }} /></div>
                <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>Importing… {csvProgress}%</div>
              </div>
            )}
            {csvMsg && (
              <div className={`alert ${csvMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                {csvMsg.text}
              </div>
            )}
            {csvParsed && !csvImporting && (
              <button className="btn btn-primary" onClick={importCSV}>
                Import {csvParsed.total.toLocaleString()} Records into Database
              </button>
            )}
          </div>
        </div>
      )}

      {/* ── DVC Sync Tab ── */}
      {dtab === 'DVC Sync' && (
        <div>
          <div className="dvc-panel">
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
              <h3>DVC — Data Version Control via GitHub Actions</h3>
              <div style={{ display: 'flex', gap: 8 }}>
                <button className="btn btn-sm btn-primary" onClick={() => runDvc('push')} disabled={dvcRunning}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
                  Trigger DVC Push
                </button>
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.8)', borderColor: 'rgba(255,255,255,0.15)' }} onClick={() => runDvc('pull')} disabled={dvcRunning}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>
                  Trigger DVC Pull
                </button>
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.8)', borderColor: 'rgba(255,255,255,0.15)' }} onClick={refreshDvcRuns}>
                  Refresh Status
                </button>
              </div>
            </div>
            <div style={{ fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 10, display: 'flex', gap: 24 }}>
              <span>Tracked: <span style={{ color: '#4ade80' }}>tomato</span>, <span style={{ color: '#4ade80' }}>burmese_grape_leaf</span></span>
              <span>Workflow files: <span style={{ color: '#4ade80' }}>dvc-push.yml</span>, <span style={{ color: '#4ade80' }}>dvc-pull.yml</span></span>
            </div>
            {!getGitHubConfig().ghToken && (
              <div style={{ background: 'rgba(202,138,4,0.15)', border: '1px solid rgba(202,138,4,0.3)', borderRadius: 8, padding: '10px 14px', fontSize: 12, color: '#fde68a', marginBottom: 10 }}>
                ⚠ GitHub not configured. Go to <strong>Settings → Integrations</strong> to add your token.
              </div>
            )}
            {dvcLog.length > 0 && (
              <div className="dvc-log">
                {dvcLog.map((line, i) => <div key={i}>{line}</div>)}
              </div>
            )}
          </div>

          {dvcRuns && (
            <div className="card">
              <div className="card-header"><div><div className="card-label">Recent</div><div className="card-title">DVC Workflow Runs</div></div></div>
              {dvcRuns.workflow_runs?.map(run => (
                <div key={run.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                  <div>
                    <span className={`status-dot ${run.conclusion === 'success' ? 'green' : run.status === 'in_progress' ? 'yellow' : 'red'}`} style={{ marginRight: 8 }} />
                    <a href={run.html_url} target="_blank" rel="noopener noreferrer" style={{ color: '#121c28', textDecoration: 'none', fontWeight: 500 }}>Run #{run.run_number} — {run.name}</a>
                  </div>
                  <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                    <span className={`badge ${run.conclusion === 'success' ? 'badge-green' : run.status === 'in_progress' ? 'badge-yellow' : 'badge-red'}`}>{run.status === 'in_progress' ? 'Running' : run.conclusion || run.status}</span>
                    <span style={{ fontSize: 11, color: '#94a3b8' }}>{new Date(run.created_at).toLocaleString()}</span>
                  </div>
                </div>
              ))}
            </div>
          )}

          <div className="card">
            <div className="card-header"><div><div className="card-label">Setup Guide</div><div className="card-title">Required GitHub Actions Workflows</div></div></div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 14 }}>Create these workflow files in <code>.github/workflows/</code> in your repository:</p>
            {[
              { file: 'dvc-push.yml', desc: 'Runs dvc push to sync local data to DVC remote storage (S3/GDrive/etc)' },
              { file: 'dvc-pull.yml', desc: 'Runs dvc pull to fetch latest data from DVC remote' },
              { file: 'validate-model.yml', desc: 'Runs inference validation pipeline with leaf_type input parameter' },
            ].map(w => (
              <div key={w.file} style={{ display: 'flex', gap: 12, padding: '10px 0', borderBottom: '1px solid rgba(0,0,0,0.06)' }}>
                <code style={{ background: '#f0fdf4', color: '#065f46', padding: '2px 8px', borderRadius: 4, fontSize: 12, flexShrink: 0 }}>{w.file}</code>
                <span style={{ fontSize: 13, color: '#3d4f62' }}>{w.desc}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Export Tab ── */}
      {dtab === 'Export' && (
        <div className="card" style={{ maxWidth: 500 }}>
          <div className="card-header"><div><div className="card-label">Export</div><div className="card-title">Download Dataset</div></div></div>
          <p style={{ fontSize: 13, color: '#64748b', marginBottom: 20 }}>Export up to 50,000 most recent prediction records from the database.</p>
          <div style={{ display: 'flex', gap: 12 }}>
            <button className="btn btn-primary" style={{ flex: 1, justifyContent: 'center' }} onClick={() => exportAll('csv')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
              Export CSV
            </button>
            <button className="btn" style={{ flex: 1, justifyContent: 'center' }} onClick={() => exportAll('json')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
              Export JSON
            </button>
          </div>
        </div>
      )}

      {/* ── Storage Files Tab ── */}
      {dtab === 'Storage Files' && (
        <div className="card">
          <div className="card-header">
            <div><div className="card-label">Storage</div><div className="card-title">Uploaded Dataset Files</div></div>
            <button className="btn btn-sm btn-primary" onClick={loadStorageFiles} disabled={storageLoading}>
              {storageLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Refresh'}
            </button>
          </div>
          {storageLoading && storedFiles.length === 0 ? (
            <div className="loading-spinner"><div className="spinner" /></div>
          ) : storedFiles.length > 0 ? (
            <div className="table-wrapper">
              <table>
                <thead><tr><th>Folder</th><th>Filename</th><th>Size</th><th>Created</th><th>Actions</th></tr></thead>
                <tbody>
                  {storedFiles.map(f => (
                    <tr key={f.path}>
                      <td><span className="badge badge-primary">{f.folder}</span></td>
                      <td style={{ fontSize: 13, maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>{f.name}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{formatBytes(f.metadata?.size || 0)}</td>
                      <td style={{ fontSize: 12, color: '#94a3b8' }}>{f.created_at ? new Date(f.created_at).toLocaleDateString() : '—'}</td>
                      <td>
                        <div style={{ display: 'flex', gap: 5 }}>
                          <a href={supabase.storage.from('datasets').getPublicUrl(f.path).data.publicUrl} target="_blank" rel="noopener noreferrer" className="btn btn-sm">Download</a>
                          <button className="btn btn-sm btn-danger" onClick={() => deleteStorageFile(f)}>Delete</button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="empty-state"><p>No files in datasets bucket. Upload files in the "Upload Dataset" tab.</p></div>
          )}
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )

  async function loadStorageFiles() {
    setStorageLoading(true)
    try {
      const { data: folders } = await supabase.storage.from('datasets').list('', { limit: 100 })
      const allFiles = []
      for (const folder of (folders || [])) {
        if (folder.id) {
          allFiles.push({ ...folder, folder: '(root)', path: folder.name })
          continue
        }
        const { data: files } = await supabase.storage.from('datasets').list(folder.name, { limit: 100 })
        for (const f of (files || [])) {
          allFiles.push({ ...f, folder: folder.name, path: `${folder.name}/${f.name}` })
        }
      }
      setStoredFiles(allFiles)
    } catch (err) { setError('Failed to list storage: ' + err.message) }
    setStorageLoading(false)
  }

  function deleteStorageFile(f) {
    setConfirmAction({
      title: 'Delete File',
      message: `Permanently delete "${f.name}" from datasets/${f.folder}? This cannot be undone.`,
      danger: true,
      confirmLabel: 'Delete',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error } = await supabase.storage.from('datasets').remove([f.path])
        if (error) alert('Delete failed: ' + error.message)
        else loadStorageFiles()
      }
    })
  }
}
