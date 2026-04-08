import { useState, useEffect, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { downloadFile, formatBytes, formatDateTime, triggerGitHubWorkflow, getGitHubWorkflowRuns, getGitHubConfig, logAudit } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const DTABS = ['Overview', 'Stage Data', 'DVC Operations', 'Prediction Data', 'Storage Files']

export default function DataManagementPage() {
  const [dtab, setDtab] = useState('Overview')
  const [stats, setStats] = useState({ total: 0 })
  const [quality, setQuality] = useState([])
  const [loading, setLoading] = useState(true)
  const [leafOptions, setLeafOptions] = useState([])

  // DVC datasets (from dvc_operations metadata or GitHub .dvc files fallback)
  const [dvcDatasets, setDvcDatasets] = useState([])
  const [dvcDatasetsLoading, setDvcDatasetsLoading] = useState(false)
  const [dvcDatasetsSource, setDvcDatasetsSource] = useState(null) // 'db' | 'github' | null

  // DVC Operations tracking (DB-backed, mirrors ModelsPage pipeline_runs pattern)
  const [dvcOps, setDvcOps] = useState([])
  const [dvcOpStatus, setDvcOpStatus] = useState(null)
  const [dvcOpDismissed, setDvcOpDismissed] = useState(false)
  const realtimeChannelRef = useRef(null)
  const ghPollRef = useRef(null)

  // Stage Data — Method A (predictions)
  const [dsLeafType, setDsLeafType] = useState('')
  const [dsPredPreview, setDsPredPreview] = useState(null)
  const [dsUploading, setDsUploading] = useState(false)
  const [dsMsg, setDsMsg] = useState(null)
  const [dsConfidence, setDsConfidence] = useState('0.8')

  // Stage Data — Method B (GDrive / Kaggle)
  const [dsExternalSource, setDsExternalSource] = useState('gdrive')
  const [dsGdriveUrl, setDsGdriveUrl] = useState('')
  const [dsKaggleUrl, setDsKaggleUrl] = useState('')
  const [dsExternalName, setDsExternalName] = useState('')
  const [dsExternalLeaf, setDsExternalLeaf] = useState('')

  // DVC Operations tab
  const [dvcPullLeaf, setDvcPullLeaf] = useState('')
  const [dvcRunning, setDvcRunning] = useState(false)
  const [dvcLog, setDvcLog] = useState([])

  // CSV import state
  const [csvFile, setCsvFile] = useState(null)
  const [csvParsed, setCsvParsed] = useState(null)
  const [csvImporting, setCsvImporting] = useState(false)
  const [csvProgress, setCsvProgress] = useState(0)
  const [csvMsg, setCsvMsg] = useState(null)
  const csvRef = useRef()
  const [showImportCsv, setShowImportCsv] = useState(false)

  // Storage Files state
  const [storedFiles, setStoredFiles] = useState([])
  const [storageLoading, setStorageLoading] = useState(false)
  const [storageBucket, setStorageBucket] = useState('datasets')
  const [confirmAction, setConfirmAction] = useState(null)
  const [error, setError] = useState(null)
  const [storageSubTab, setStorageSubTab] = useState('Datasets') // 'Datasets' | 'Prediction Images'

  // Prediction Images browser
  const [predImages, setPredImages] = useState([])
  const [predImagesLoading, setPredImagesLoading] = useState(false)
  const [predImgLeaf, setPredImgLeaf] = useState('')
  const [predImgPage, setPredImgPage] = useState(0)
  const [predImgHasMore, setPredImgHasMore] = useState(false)
  const [previewImg, setPreviewImg] = useState(null) // { url, prediction }
  const [editingLabel, setEditingLabel] = useState(null) // prediction id being edited
  const [editLabelValue, setEditLabelValue] = useState('')

  useEffect(() => { loadData(); loadDvcOperations() }, [])

  useEffect(() => {
    if (dtab === 'Storage Files') {
      if (storageSubTab === 'Datasets' && storedFiles.length === 0) loadStorageFiles()
      if (storageSubTab === 'Prediction Images' && predImages.length === 0) loadPredictionImages(true)
    }
  }, [dtab])

  useEffect(() => {
    return () => {
      if (ghPollRef.current) clearInterval(ghPollRef.current)
      if (realtimeChannelRef.current) supabase.removeChannel(realtimeChannelRef.current)
    }
  }, [])

  // ── Load data ─────────────────────────────────────────────────────────────
  const loadData = async () => {
    setLoading(true)
    setError(null)
    try {
      const [{ data: rpcStats }, { data: leafTypeOpts }] = await Promise.all([
        supabase.rpc('get_dashboard_stats', { p_leaf_type: null }),
        supabase.rpc('get_leaf_type_options'),
      ])
      const s = rpcStats || {}
      setStats({ total: s.total || 0 })
      const leafTypes = (leafTypeOpts || []).map(r => r.leaf_type).filter(Boolean)
      setLeafOptions(leafTypes)

      const qualityResults = await Promise.all(
        leafTypes.map(async lt => {
          const { data: ltStats } = await supabase.rpc('get_dashboard_stats', { p_leaf_type: lt })
          const ls = ltStats || {}
          return { name: lt, total: ls.total || 0 }
        })
      )
      setQuality(qualityResults)
      fetchTrackedDatasets()
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  // ── DVC Operations — DB-backed tracking ───────────────────────────────────
  const loadDvcOperations = async () => {
    try {
      const { data } = await supabase.from('dvc_operations').select('*').order('started_at', { ascending: false }).limit(20)
      const ops = data || []

      // Auto-cleanup stale ops (>30 min without update)
      const STALE_MS = 30 * 60 * 1000
      for (const op of ops) {
        if (['pending', 'staging', 'pushing', 'pulling', 'exporting'].includes(op.status)) {
          const age = Date.now() - new Date(op.started_at).getTime()
          if (age > STALE_MS) {
            await supabase.from('dvc_operations').update({
              status: 'failed',
              error_message: 'Stale: no update for >30 minutes',
              completed_at: new Date().toISOString(),
            }).eq('id', op.id)
            op.status = 'failed'
            op.error_message = 'Stale: no update for >30 minutes'
          }
        }
      }

      setDvcOps(ops)
      if (ops.length) {
        const latest = ops[0]
        if (['pending', 'staging', 'pushing', 'pulling', 'exporting'].includes(latest.status)) {
          setDvcOpStatus(latest.status)
          setDvcOpDismissed(false)
        } else if (latest.status === 'staged') {
          setDvcOpStatus('staged')
          setDvcOpDismissed(false)
        }
      }
    } catch (err) {
      console.warn('dvc_operations load failed:', err.message)
    }
  }

  // ── Realtime subscription (mirrors subscribeToPipelineRun) ────────────────
  const subscribeToDvcOp = (opId) => {
    if (realtimeChannelRef.current) supabase.removeChannel(realtimeChannelRef.current)
    startGitHubPolling()
    const channel = supabase
      .channel(`dvc-op-${opId}`)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'dvc_operations',
        filter: `id=eq.${opId}`
      }, (payload) => {
        const newStatus = payload.new.status
        setDvcOpStatus(newStatus)
        setDvcOpDismissed(false)
        setDvcOps(prev => prev.map(o => o.id === opId ? { ...o, ...payload.new } : o))
        if (['completed', 'failed', 'staged'].includes(newStatus)) {
          supabase.removeChannel(channel)
          realtimeChannelRef.current = null
          if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
          fetchTrackedDatasets()
          loadDvcOperations()
        }
      })
      .subscribe((status) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          console.warn('Realtime subscription failed — relying on GitHub API polling fallback')
        }
      })
    realtimeChannelRef.current = channel
  }

  // ── GitHub polling fallback ───────────────────────────────────────────────
  const startGitHubPolling = () => {
    if (ghPollRef.current) clearInterval(ghPollRef.current)
    ghPollRef.current = setInterval(async () => {
      try {
        // Poll multiple DVC-related workflows
        for (const wf of ['dataset-upload.yml', 'dvc-pull.yml', 'dvc-push.yml', 'export-data.yml']) {
          const data = await getGitHubWorkflowRuns(wf)
          if (!data?.workflow_runs?.length) continue
          const latest = data.workflow_runs[0]
          const runAge = Date.now() - new Date(latest.created_at).getTime()
          if (runAge > 30 * 60 * 1000) continue

          if (latest.status === 'completed') {
            // Refresh from DB to get the actual status set by the workflow
            loadDvcOperations()
            clearInterval(ghPollRef.current)
            ghPollRef.current = null
            fetchTrackedDatasets()
            return
          } else {
            const mapped = latest.status === 'queued' ? 'pending' : latest.status === 'in_progress' ? 'staging' : null
            if (mapped) {
              setDvcOpStatus(mapped)
              setDvcOpDismissed(false)
            }
          }
        }
      } catch { /* GitHub API may not be configured */ }
    }, 15000)
  }

  // ── Trigger staging (two-stage step 1) ────────────────────────────────────
  const triggerStaging = async (source, inputs) => {
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }
    setDsUploading(true); setDsMsg(null)
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations.')

      const { data: { user } } = await supabase.auth.getUser()
      const { data: op, error: opErr } = await supabase.from('dvc_operations').insert({
        leaf_type: inputs.leaf_type,
        operation: 'stage',
        source,
        status: 'pending',
        metadata: {
          confidence_threshold: inputs.confidence_threshold || null,
          source_url: inputs.gdrive_url || inputs.kaggle_url || null,
          display_name: inputs.display_name || inputs.leaf_type,
        },
        triggered_by: user?.id,
      }).select().single()

      if (opErr) throw new Error('Failed to create dvc_operations row: ' + opErr.message)

      await triggerGitHubWorkflow('dataset-upload.yml', {
        source,
        ...inputs,
        dvc_operation_id: op.id,
        stage_only: 'true',
      })

      setDvcOps(prev => [op, ...prev])
      subscribeToDvcOp(op.id)
      setDvcOpStatus('pending')
      setDsMsg({ type: 'success', text: `Staging workflow dispatched. Data will be uploaded to Storage for review.` })
      logAudit(supabase, 'dvc_staging_triggered', 'dvc_operation', op.id, { source, leaf_type: inputs.leaf_type })
    } catch (err) {
      setDsMsg({ type: 'error', text: err.message })
    } finally {
      setDsUploading(false)
    }
  }

  // ── Trigger DVC push (two-stage step 2) ───────────────────────────────────
  const triggerDvcPush = async (stagedOp) => {
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured.')

      const { data: { user } } = await supabase.auth.getUser()
      const { data: pushOp, error: opErr } = await supabase.from('dvc_operations').insert({
        leaf_type: stagedOp.leaf_type,
        operation: 'push',
        source: stagedOp.source || 'manual',
        status: 'pending',
        metadata: { staged_from_operation: stagedOp.id, staging_path: stagedOp.metadata?.staging_path },
        triggered_by: user?.id,
      }).select().single()

      if (opErr) throw new Error('Failed to create push operation: ' + opErr.message)

      await triggerGitHubWorkflow('dataset-upload.yml', {
        source: stagedOp.source || 'manual',
        leaf_type: stagedOp.leaf_type,
        dvc_operation_id: pushOp.id,
        stage_only: 'false',
        display_name: stagedOp.metadata?.display_name || stagedOp.leaf_type,
      })

      setDvcOps(prev => [pushOp, ...prev])
      subscribeToDvcOp(pushOp.id)
      setDvcOpStatus('pending')
      logAudit(supabase, 'dvc_push_triggered', 'dvc_operation', pushOp.id, { leaf_type: stagedOp.leaf_type })
    } catch (err) {
      setDsMsg({ type: 'error', text: err.message })
    }
  }

  // ── Trigger DVC pull/verify ───────────────────────────────────────────────
  const triggerDvcPull = async (leafType = '') => {
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }
    setDvcRunning(true); setDvcLog([])
    const ts = () => new Date().toLocaleTimeString()
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations.')

      const { data: { user } } = await supabase.auth.getUser()
      const { data: op } = await supabase.from('dvc_operations').insert({
        leaf_type: leafType || 'all',
        operation: 'pull',
        source: 'dvc_remote',
        status: 'pending',
        triggered_by: user?.id,
      }).select().single()

      const inputs = { dvc_operation_id: op?.id || '' }
      if (leafType) inputs.leaf_type = leafType

      setDvcLog(l => [...l, `[${ts()}] Triggering DVC pull${leafType ? ` (${leafType})` : ' (all)'}…`])
      await triggerGitHubWorkflow('dvc-pull.yml', inputs)
      setDvcLog(l => [...l, `[${ts()}] Workflow dispatched. Tracking progress…`])

      if (op) {
        setDvcOps(prev => [op, ...prev])
        subscribeToDvcOp(op.id)
      }
      setDvcOpStatus('pending')
    } catch (err) {
      let msg = err.message
      if (err instanceof TypeError && msg.includes('fetch')) {
        msg = `Network error — check your PAT has "actions" and "workflow" permissions.`
      }
      setDvcLog(l => [...l, `[${ts()}] Error: ${msg}`])
    } finally {
      setDvcRunning(false)
    }
  }

  // ── Trigger DVC push all ──────────────────────────────────────────────────
  const triggerDvcPushAll = async () => {
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }
    setDvcRunning(true); setDvcLog([])
    const ts = () => new Date().toLocaleTimeString()
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured.')

      const { data: { user } } = await supabase.auth.getUser()
      const { data: op } = await supabase.from('dvc_operations').insert({
        leaf_type: 'all',
        operation: 'push',
        source: 'manual',
        status: 'pending',
        triggered_by: user?.id,
      }).select().single()

      setDvcLog(l => [...l, `[${ts()}] Triggering DVC push (all)…`])
      await triggerGitHubWorkflow('dvc-push.yml', { dvc_operation_id: op?.id || '' })
      setDvcLog(l => [...l, `[${ts()}] Workflow dispatched. Tracking progress…`])

      if (op) {
        setDvcOps(prev => [op, ...prev])
        subscribeToDvcOp(op.id)
      }
      setDvcOpStatus('pending')
    } catch (err) {
      setDvcLog(l => [...l, `[${ts()}] Error: ${err.message}`])
    } finally {
      setDvcRunning(false)
    }
  }

  // ── Trigger export data ───────────────────────────────────────────────────
  const triggerExportData = async () => {
    setDvcRunning(true)
    const ts = () => new Date().toLocaleTimeString()
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured.')

      const { data: { user } } = await supabase.auth.getUser()
      const { data: op } = await supabase.from('dvc_operations').insert({
        leaf_type: 'all',
        operation: 'export',
        source: 'predictions',
        status: 'pending',
        triggered_by: user?.id,
      }).select().single()

      setDvcLog(l => [...l, `[${ts()}] Triggering export-data workflow…`])
      await triggerGitHubWorkflow('export-data.yml', { dvc_operation_id: op?.id || '' })
      setDvcLog(l => [...l, `[${ts()}] Workflow dispatched. Tracking progress…`])

      if (op) {
        setDvcOps(prev => [op, ...prev])
        subscribeToDvcOp(op.id)
      }
      setDvcOpStatus('pending')
    } catch (err) {
      setDvcLog(l => [...l, `[${ts()}] Error: ${err.message}`])
    } finally {
      setDvcRunning(false)
    }
  }

  // ── Discard staged data ───────────────────────────────────────────────────
  const discardStaged = async (op) => {
    try {
      // Delete staged file from storage
      if (op.metadata?.staging_path) {
        await supabase.storage.from(op.metadata?.staging_bucket || 'datasets').remove([op.metadata.staging_path])
      }
      await supabase.from('dvc_operations').update({
        status: 'failed',
        error_message: 'Discarded by admin',
        completed_at: new Date().toISOString(),
      }).eq('id', op.id)
      loadDvcOperations()
    } catch (err) {
      console.warn('Discard failed:', err.message)
    }
  }

  // ── Fetch DVC datasets from GitHub ────────────────────────────────────────
  const fetchTrackedDatasets = async () => {
    setDvcDatasetsLoading(true)
    try {
      // Primary: get latest completed pull/push/stage per leaf_type from dvc_operations
      const { data: ops } = await supabase
        .from('dvc_operations')
        .select('leaf_type, metadata, completed_at')
        .in('operation', ['pull', 'push', 'stage'])
        .eq('status', 'completed')
        .not('metadata', 'is', null)
        .order('completed_at', { ascending: false })
        .limit(50)

      if (ops && ops.length > 0) {
        const seen = new Set()
        const datasets = []
        for (const op of ops) {
          const md = op.metadata
          if (md?.datasets) {
            for (const [dsName, dsInfo] of Object.entries(md.datasets)) {
              if (seen.has(dsName)) continue
              seen.add(dsName)
              datasets.push({
                name: dsName,
                file: `data_${dsName}.dvc`,
                size: dsInfo.total_size || null,
                nfiles: dsInfo.file_count || null,
                md5: dsInfo.dvc_md5 || null,
                num_classes: dsInfo.num_classes || (dsInfo.classes ? Object.keys(dsInfo.classes).length : null),
                classes: dsInfo.classes || null,
                lastUpdated: op.completed_at,
              })
            }
          } else if (md?.file_count != null && !seen.has(op.leaf_type)) {
            seen.add(op.leaf_type)
            datasets.push({
              name: op.leaf_type,
              file: `data_${op.leaf_type}.dvc`,
              size: md.total_size || null,
              nfiles: md.file_count || null,
              md5: md.dvc_md5 || null,
              num_classes: md.num_classes || (md.classes ? Object.keys(md.classes).length : null),
              classes: md.classes || null,
              lastUpdated: op.completed_at,
            })
          }
        }
        if (datasets.length > 0) {
          setDvcDatasets(datasets)
          setDvcDatasetsSource('db')
          setDvcDatasetsLoading(false)
          return
        }
      }

      // Fallback: read .dvc files from GitHub repo
      const { ghToken, ghOwner, ghRepo, ghBranch } = getGitHubConfig()
      if (!ghToken || !ghOwner || !ghRepo) {
        setDvcDatasetsSource(null)
        setDvcDatasetsLoading(false)
        return
      }
      const res = await fetch(
        `https://api.github.com/repos/${ghOwner}/${ghRepo}/contents?ref=${ghBranch}`,
        { headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' } }
      )
      if (!res.ok) throw new Error(`GitHub API ${res.status}`)
      const files = await res.json()
      const dvcFiles = files.filter(f => f.name.endsWith('.dvc') && f.name.startsWith('data_'))
      const datasets = []
      for (const df of dvcFiles) {
        const contentRes = await fetch(df.download_url)
        const content = await contentRes.text()
        const leafType = df.name.replace('data_', '').replace('.dvc', '')
        const sizeMatch = content.match(/size:\s*(\d+)/)
        const nfilesMatch = content.match(/nfiles:\s*(\d+)/)
        const md5Match = content.match(/md5:\s*(\S+)/)
        datasets.push({
          name: leafType, file: df.name,
          size: sizeMatch ? parseInt(sizeMatch[1]) : null,
          nfiles: nfilesMatch ? parseInt(nfilesMatch[1]) : null,
          md5: md5Match ? md5Match[1] : null,
          num_classes: null, classes: null, lastUpdated: null,
        })
      }
      setDvcDatasets(datasets)
      setDvcDatasetsSource('github')
    } catch (err) {
      console.warn('Failed to fetch tracked datasets:', err.message)
    }
    setDvcDatasetsLoading(false)
  }

  // ── Prediction Images browser ────────────────────────────────────────────
  const PAGE_SIZE = 20
  const loadPredictionImages = async (reset = false) => {
    setPredImagesLoading(true)
    const page = reset ? 0 : predImgPage
    const from = page * PAGE_SIZE
    let query = supabase.from('predictions')
      .select('id, leaf_type, predicted_class_name, confidence, image_url, created_at')
      .not('image_url', 'is', null)
      .order('created_at', { ascending: false })
      .range(from, from + PAGE_SIZE)
    if (predImgLeaf) query = query.eq('leaf_type', predImgLeaf)
    const { data } = await query
    const rows = data || []

    // range() is inclusive: range(0,20) returns up to 21 items. If we get 21, there's more data.
    const hasMore = rows.length === PAGE_SIZE + 1
    const display = hasMore ? rows.slice(0, PAGE_SIZE) : rows

    // Generate signed URLs for thumbnails (private bucket)
    const withUrls = await Promise.all(display.map(async (r) => {
      if (!r.image_url) return { ...r, signedUrl: null }
      try {
        const match = r.image_url.match(/prediction-images\/(.+)$/)
        if (!match) return { ...r, signedUrl: null }
        const storagePath = match[1]
        const { data: signed } = await supabase.storage.from('prediction-images').createSignedUrl(storagePath, 3600)
        return { ...r, signedUrl: signed?.signedUrl || null }
      } catch { return { ...r, signedUrl: null } }
    }))

    if (reset) {
      setPredImages(withUrls)
      setPredImgPage(1)
    } else {
      setPredImages(prev => [...prev, ...withUrls])
      setPredImgPage(page + 1)
    }
    setPredImgHasMore(hasMore)
    setPredImagesLoading(false)
  }

  const savePredLabel = async (predId, newLabel) => {
    await supabase.from('predictions').update({ predicted_class_name: newLabel }).eq('id', predId)
    setPredImages(prev => prev.map(p => p.id === predId ? { ...p, predicted_class_name: newLabel } : p))
    setEditingLabel(null)
  }

  const openPreview = async (pred) => {
    if (pred.signedUrl) {
      setPreviewImg({ url: pred.signedUrl, prediction: pred })
    } else if (pred.image_url) {
      const match = pred.image_url.match(/prediction-images\/(.+)$/)
      if (match) {
        const { data: signed } = await supabase.storage.from('prediction-images').createSignedUrl(match[1], 3600)
        setPreviewImg({ url: signed?.signedUrl || pred.image_url, prediction: pred })
      }
    }
  }

  // ── Preview predictions ───────────────────────────────────────────────────
  const previewPredictions = async () => {
    if (!dsLeafType) return
    let query = supabase.from('predictions').select('predicted_class_name, confidence').eq('leaf_type', dsLeafType)
    const threshold = parseFloat(dsConfidence)
    if (!isNaN(threshold) && threshold > 0) query = query.gte('confidence', threshold)
    const { data, error } = await query
    if (error || !data) { setDsPredPreview(null); return }
    const classMap = {}
    data.forEach(r => { classMap[r.predicted_class_name] = (classMap[r.predicted_class_name] || 0) + 1 })
    setDsPredPreview({ total: data.length, classes: classMap })
  }

  // ── CSV functions ─────────────────────────────────────────────────────────
  const parseCSVLine = (line) => {
    const values = []; let current = '', inQuotes = false
    for (let i = 0; i < line.length; i++) {
      const ch = line[i]
      if (ch === '"') { if (inQuotes && line[i + 1] === '"') { current += '"'; i++ } else inQuotes = !inQuotes }
      else if (ch === ',' && !inQuotes) { values.push(current.trim()); current = '' }
      else current += ch
    }
    values.push(current.trim()); return values
  }

  const parseCSV = async (file) => {
    const text = await file.text()
    const lines = text.split('\n').filter(l => l.trim())
    if (lines.length < 2) { setCsvMsg({ type: 'error', text: 'CSV has no data rows.' }); return }
    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''))
    const rows = lines.slice(1).map(line => {
      const values = parseCSVLine(line); const row = {}
      headers.forEach((h, i) => { row[h] = (values[i] || '').replace(/^"|"$/g, '') || null })
      return row
    }).filter(r => Object.values(r).some(v => v))
    setCsvParsed({ headers, rows: rows.slice(0, 10), total: rows.length, all: rows }); setCsvMsg(null)
  }

  const importCSV = async () => {
    if (!csvParsed) return
    const missing = ['leaf_type', 'predicted_class_name'].filter(r => !csvParsed.headers.includes(r))
    if (missing.length) { setCsvMsg({ type: 'error', text: `Missing required columns: ${missing.join(', ')}` }); return }
    setCsvImporting(true); setCsvProgress(0); setCsvMsg(null)
    const { all } = csvParsed; let imported = 0
    try {
      for (let i = 0; i < all.length; i += 100) {
        const batch = all.slice(i, i + 100)
        const { error } = await supabase.from('predictions').insert(batch)
        if (error) throw new Error(`Batch ${Math.floor(i / 100) + 1} failed: ${error.message}`)
        imported += batch.length; setCsvProgress(Math.round(imported / all.length * 100))
      }
      setCsvMsg({ type: 'success', text: `Imported ${imported.toLocaleString()} records.` })
      setCsvParsed(null); setCsvFile(null); if (csvRef.current) csvRef.current.value = ''
      loadData()
    } catch (err) { setCsvMsg({ type: 'error', text: err.message }) }
    finally { setCsvImporting(false) }
  }

  const exportAll = async (fmt) => {
    try {
      const { data } = await supabase.from('predictions').select('*').order('created_at', { ascending: false }).limit(50000)
      if (!data?.length) { setCsvMsg({ type: 'error', text: 'No data to export.' }); return }
      const name = `agrikd-data-${new Date().toISOString().slice(0, 10)}`
      if (fmt === 'csv') {
        const h = Object.keys(data[0])
        downloadFile([h.join(','), ...data.map(r => h.map(k => JSON.stringify(r[k] ?? '')).join(','))].join('\n'), `${name}.csv`, 'text/csv')
      } else downloadFile(JSON.stringify(data, null, 2), `${name}.json`, 'application/json')
    } catch (err) { setCsvMsg({ type: 'error', text: 'Export failed: ' + err.message }) }
  }

  // ── Helper components ─────────────────────────────────────────────────────
  const StatusBadge = ({ status }) => {
    const colors = {
      pending: 'badge-gray', staging: 'badge-yellow', staged: 'badge-primary',
      pushing: 'badge-yellow', pulling: 'badge-yellow', exporting: 'badge-yellow',
      completed: 'badge-green', failed: 'badge-red',
    }
    return <span className={`badge ${colors[status] || 'badge-gray'}`}>{status}</span>
  }

  const DvcOpBanner = ({ status, onDismiss }) => {
    if (!status || dvcOpDismissed) return null
    const isActive = ['pending', 'staging', 'pushing', 'pulling', 'exporting'].includes(status)
    const isStaged = status === 'staged'
    const isSuccess = status === 'completed'
    const isFailed = status === 'failed'
    const latest = dvcOps[0]
    return (
      <div className={`alert ${isSuccess ? 'alert-success' : isFailed ? 'alert-error' : isStaged ? 'alert-info' : 'alert-info'}`} style={{ marginBottom: 16 }}>
        {isActive && <div className="spinner" style={{ width: 16, height: 16, borderWidth: 2 }} />}
        {!isActive && <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">{isSuccess ? <path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/> : <><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></>}</svg>}
        <div style={{ flex: 1 }}>
          <strong>
            {isActive ? 'Pipeline running…' : isStaged ? 'Data staged — ready for review' : isSuccess ? 'Operation completed' : 'Operation failed'}
          </strong>
          {latest?.github_run_url && (
            <span style={{ marginLeft: 8, fontSize: 12, color: '#64748b' }}>
              <a href={latest.github_run_url} target="_blank" rel="noopener noreferrer" style={{ color: '#0284c7' }}>View on GitHub</a>
            </span>
          )}
          {isFailed && latest?.error_message && <div style={{ fontSize: 12, color: '#94a3b8', marginTop: 4 }}>{latest.error_message}</div>}
        </div>
        {!isActive && onDismiss && (
          <button onClick={onDismiss} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 16, color: '#94a3b8', padding: '0 4px' }}>×</button>
        )}
      </div>
    )
  }

  const ghNotConfigured = !getGitHubConfig().ghToken
  const isOperationActive = ['pending', 'staging', 'pushing', 'pulling', 'exporting'].includes(dvcOpStatus)
  const stagedOps = dvcOps.filter(o => o.status === 'staged')

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading data…</span></div>

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Data & DVC</h1>
        <p className="page-subtitle">Training datasets (DVC), staging, user prediction data, and storage management</p>
      </div>

      {/* Tab nav */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {DTABS.map(t => (
          <button key={t} onClick={() => setDtab(t)} style={{ padding: '10px 16px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: dtab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${dtab === t ? '#16a34a' : 'transparent'}`, fontFamily: 'inherit' }}>
            {t}
            {t === 'Stage Data' && stagedOps.length > 0 && <span style={{ marginLeft: 6, background: '#f59e0b', color: '#fff', borderRadius: 10, padding: '1px 7px', fontSize: 11 }}>{stagedOps.length}</span>}
          </button>
        ))}
      </div>

      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}>{error}</div>}

      {/* ── Overview Tab ── */}
      {dtab === 'Overview' && (
        <>
          <div className="stats-grid" style={{ marginBottom: 16 }}>
            {[
              { label: 'Total Predictions', value: stats.total.toLocaleString(), accent: '#16a34a' },
              { label: 'DVC Datasets', value: dvcDatasetsLoading ? '…' : String(dvcDatasets.length), accent: '#0284c7' },
              { label: 'Operations', value: String(dvcOps.length), accent: '#8b5cf6' },
            ].map(s => (
              <div key={s.label} className="stat-card" style={{ padding: '14px 16px' }}>
                <div className="stat-card-accent" style={{ background: s.accent }} />
                <div className="stat-label">{s.label}</div>
                <div className="stat-value" style={{ fontSize: 22 }}>{s.value}</div>
              </div>
            ))}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 20 }}>
            <div className="card">
              <div className="card-header"><div><div className="card-label">User Predictions</div><div className="card-title">Records by Leaf Type</div></div></div>
              <table>
                <thead><tr><th>Leaf Type</th><th>Total Records</th></tr></thead>
                <tbody>
                  {quality.map(q => <tr key={q.name}><td><strong style={{ color: '#121c28' }}>{q.name}</strong></td><td>{q.total.toLocaleString()}</td></tr>)}
                  {quality.length === 0 && <tr><td colSpan={2} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No prediction data yet</td></tr>}
                </tbody>
              </table>
            </div>

            <div className="card">
              <div className="card-header">
                <div><div className="card-label">Training Data (DVC)</div><div className="card-title">Tracked Datasets</div></div>
                <button className="btn btn-sm" onClick={fetchTrackedDatasets} disabled={dvcDatasetsLoading}>
                  {dvcDatasetsLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Refresh'}
                </button>
              </div>
              {dvcDatasets.length > 0 ? (
                <table>
                  <thead><tr><th>Dataset</th><th>Classes</th><th>Images</th><th>Size</th><th>Version</th><th>Updated</th></tr></thead>
                  <tbody>
                    {dvcDatasets.map(ds => (
                      <tr key={ds.name}>
                        <td><span className="badge badge-primary">{ds.name}</span></td>
                        <td>{ds.num_classes != null ? ds.num_classes : '—'}</td>
                        <td>{ds.nfiles != null ? ds.nfiles.toLocaleString() : '—'}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{ds.size != null ? formatBytes(ds.size) : '—'}</td>
                        <td style={{ fontSize: 11, color: '#94a3b8', fontFamily: 'monospace' }}>{ds.md5 ? ds.md5.slice(0, 8) + '…' : '—'}</td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{ds.lastUpdated ? formatDateTime(ds.lastUpdated) : '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : <div className="empty-state"><p>{dvcDatasetsLoading ? 'Loading…' : 'No tracked datasets yet. Run a DVC Pull or Push to populate.'}</p></div>}
              {dvcDatasetsSource && <div style={{ fontSize: 11, color: '#94a3b8', padding: '6px 16px' }}>Source: {dvcDatasetsSource === 'db' ? 'DVC operations history' : 'GitHub .dvc files'}</div>}
            </div>
          </div>

          {/* Recent Operations */}
          {dvcOps.length > 0 && (
            <div className="card">
              <div className="card-header"><div><div className="card-label">Activity</div><div className="card-title">Recent DVC Operations</div></div></div>
              <table>
                <thead><tr><th>Operation</th><th>Dataset</th><th>Status</th><th>Details</th><th>Started</th></tr></thead>
                <tbody>
                  {dvcOps.slice(0, 5).map(op => (
                    <tr key={op.id}>
                      <td><span className="badge">{op.operation}</span></td>
                      <td><strong style={{ color: '#121c28' }}>{op.leaf_type}</strong></td>
                      <td><StatusBadge status={op.status} /></td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>
                        {op.metadata?.file_count != null && <span>{op.metadata.file_count} files</span>}
                        {op.metadata?.total_size != null && <span style={{ marginLeft: 6 }}>{formatBytes(op.metadata.total_size)}</span>}
                        {op.metadata?.num_classes != null && <span style={{ marginLeft: 6 }}>{op.metadata.num_classes} classes</span>}
                        {op.error_message && <span style={{ color: '#ef4444' }}> {op.error_message}</span>}
                      </td>
                      <td style={{ fontSize: 12, color: '#94a3b8' }}>{formatDateTime(op.started_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      {/* ── Stage Data Tab ── */}
      {dtab === 'Stage Data' && (
        <div>
          {ghNotConfigured && (
            <div className="alert alert-warn" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
              <div>GitHub not configured. Go to <strong>Settings &rarr; Integrations</strong> to add your token.</div>
            </div>
          )}

          <DvcOpBanner status={dvcOpStatus} onDismiss={() => setDvcOpDismissed(true)} />

          {dsMsg && (
            <div className={`alert ${dsMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
              <div>{dsMsg.text}</div>
            </div>
          )}

          {/* Staged data waiting for review */}
          {stagedOps.length > 0 && (
            <div className="card" style={{ marginBottom: 20, border: '2px solid #f59e0b' }}>
              <div className="card-header">
                <div><div className="card-label" style={{ color: '#f59e0b' }}>Ready for Review</div><div className="card-title">Staged Datasets</div></div>
              </div>
              {stagedOps.map(op => (
                <div key={op.id} style={{ padding: '12px 16px', borderBottom: '1px solid rgba(0,0,0,0.06)' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                    <div>
                      <strong style={{ color: '#121c28' }}>{op.leaf_type}</strong>
                      <span style={{ marginLeft: 8, fontSize: 12, color: '#64748b' }}>via {op.source}</span>
                    </div>
                    <div style={{ display: 'flex', gap: 8 }}>
                      <button className="btn btn-sm btn-primary" onClick={() => triggerDvcPush(op)} disabled={isOperationActive}>Push to DVC</button>
                      <button className="btn btn-sm btn-danger" onClick={() => setConfirmAction({
                        title: 'Discard Staged Data',
                        message: `Discard staged data for "${op.leaf_type}"? The staged ZIP will be deleted from Storage.`,
                        danger: true, confirmLabel: 'Discard',
                        onConfirm: () => { setConfirmAction(null); discardStaged(op) }
                      })}>Discard</button>
                    </div>
                  </div>
                  {op.metadata && (
                    <div style={{ fontSize: 12, color: '#64748b', display: 'flex', gap: 16 }}>
                      {op.metadata.file_count != null && <span>{op.metadata.file_count} files</span>}
                      {op.metadata.total_size != null && <span>{formatBytes(op.metadata.total_size)}</span>}
                      {op.metadata.classes && <span>{Object.keys(op.metadata.classes).length} classes</span>}
                      {op.metadata.confidence_threshold && <span>confidence &ge; {op.metadata.confidence_threshold}</span>}
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}

          <div style={{ display: 'flex', gap: 20, flexWrap: 'wrap', marginBottom: 20 }}>
            {/* Method A: From Predictions */}
            <div className="card" style={{ flex: 1, minWidth: 340 }}>
              <div className="card-header"><div><div className="card-label">Method A</div><div className="card-title">From User Predictions</div></div></div>
              <div className="alert alert-info" style={{ marginBottom: 16 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
                <div>Stage user predictions as a dataset. Images are downloaded, organized by class, and uploaded to Storage for review before pushing to DVC.</div>
              </div>
              <div className="form-group">
                <label className="form-label">Leaf Type *</label>
                <select className="form-input" value={dsLeafType} onChange={e => { setDsLeafType(e.target.value); setDsPredPreview(null) }}>
                  <option value="">Select leaf type…</option>
                  {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
                </select>
              </div>
              <div className="form-group">
                <label className="form-label">Min Confidence Threshold</label>
                <input className="form-input" type="number" min="0" max="1" step="0.05" value={dsConfidence} onChange={e => { setDsConfidence(e.target.value); setDsPredPreview(null) }} />
                <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4 }}>Only predictions with confidence &ge; this value will be exported (default 0.8).</div>
              </div>
              <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
                <button className="btn btn-sm" onClick={previewPredictions} disabled={!dsLeafType}>Preview Count</button>
              </div>
              {dsPredPreview && (
                <div style={{ marginBottom: 14, padding: '10px 14px', background: '#f8fafc', borderRadius: 8, fontSize: 13 }}>
                  <div style={{ fontWeight: 600, marginBottom: 6 }}>Found {dsPredPreview.total} images (confidence &ge; {dsConfidence}):</div>
                  {Object.entries(dsPredPreview.classes).map(([cls, n]) => (
                    <div key={cls} style={{ display: 'flex', justifyContent: 'space-between', padding: '2px 0' }}><span>{cls}</span><span style={{ color: '#64748b' }}>{n}</span></div>
                  ))}
                </div>
              )}
              <button className="btn btn-primary" disabled={dsUploading || !dsLeafType || !dsPredPreview?.total || ghNotConfigured || isOperationActive}
                onClick={() => triggerStaging('predictions', { leaf_type: dsLeafType, confidence_threshold: dsConfidence })}>
                {dsUploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Staging…</> : 'Stage Dataset'}
              </button>
            </div>

            {/* Method B: External Source */}
            <div className="card" style={{ flex: 1, minWidth: 340 }}>
              <div className="card-header"><div><div className="card-label">Method B</div><div className="card-title">From External Source</div></div></div>
              <div className="alert alert-info" style={{ marginBottom: 16 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
                <div>Download dataset from Google Drive or Kaggle, validate structure, and stage to Storage for review.<br/><strong>Expected structure:</strong> <code>dataset_name/class_name/images.*</code></div>
              </div>
              <div className="form-group">
                <label className="form-label">Source</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  {[{ v: 'gdrive', l: 'Google Drive' }, { v: 'kaggle', l: 'Kaggle' }].map(opt => (
                    <button key={opt.v} className={`btn btn-sm ${dsExternalSource === opt.v ? 'btn-primary' : ''}`}
                      onClick={() => setDsExternalSource(opt.v)} style={{ flex: 1 }}>{opt.l}</button>
                  ))}
                </div>
              </div>
              {dsExternalSource === 'gdrive' && (
                <div className="form-group">
                  <label className="form-label">Google Drive Share URL *</label>
                  <input className="form-input" placeholder="https://drive.google.com/file/d/..." value={dsGdriveUrl} onChange={e => setDsGdriveUrl(e.target.value)} />
                </div>
              )}
              {dsExternalSource === 'kaggle' && (
                <div className="form-group">
                  <label className="form-label">Kaggle Dataset URL *</label>
                  <input className="form-input" placeholder="https://www.kaggle.com/datasets/user/dataset-name" value={dsKaggleUrl} onChange={e => setDsKaggleUrl(e.target.value)} />
                  <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4 }}>Requires KAGGLE_USERNAME and KAGGLE_KEY secrets in GitHub.</div>
                </div>
              )}
              <div className="form-group">
                <label className="form-label">Leaf Type ID *</label>
                <input className="form-input" placeholder="e.g. mango, cassava_leaf" value={dsExternalLeaf} onChange={e => setDsExternalLeaf(e.target.value)} />
                <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4 }}>Lowercase, underscores. Used for config and DVC tracking.</div>
              </div>
              <div className="form-group">
                <label className="form-label">Display Name</label>
                <input className="form-input" placeholder="e.g. Mango Leaf Disease" value={dsExternalName} onChange={e => setDsExternalName(e.target.value)} />
              </div>
              <button className="btn btn-primary"
                disabled={dsUploading || !dsExternalLeaf || ghNotConfigured || isOperationActive ||
                  (dsExternalSource === 'gdrive' && !dsGdriveUrl) || (dsExternalSource === 'kaggle' && !dsKaggleUrl)}
                onClick={() => {
                  const inputs = { leaf_type: dsExternalLeaf, display_name: dsExternalName || dsExternalLeaf }
                  if (dsExternalSource === 'gdrive') inputs.gdrive_url = dsGdriveUrl
                  if (dsExternalSource === 'kaggle') inputs.kaggle_url = dsKaggleUrl
                  triggerStaging(dsExternalSource, inputs)
                }}>
                {dsUploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Staging…</> : 'Stage Dataset'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── DVC Operations Tab ── */}
      {dtab === 'DVC Operations' && (
        <div>
          {ghNotConfigured && (
            <div className="alert alert-warn" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
              <div>GitHub not configured. Go to <strong>Settings &rarr; Integrations</strong> to add your token.</div>
            </div>
          )}

          <DvcOpBanner status={dvcOpStatus} onDismiss={() => setDvcOpDismissed(true)} />

          {/* Action cards */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16, marginBottom: 20 }}>
            {/* DVC Pull/Verify */}
            <div className="card">
              <div className="card-header"><div><div className="card-label">DVC Pull</div><div className="card-title">Verify Remote</div></div></div>
              <p style={{ fontSize: 13, color: '#64748b', marginBottom: 12, lineHeight: 1.5 }}>Pull latest datasets from DVC remote (Google Drive). Runs via GitHub Actions.</p>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <select value={dvcPullLeaf} onChange={e => setDvcPullLeaf(e.target.value)} className="form-input" style={{ flex: 1 }}>
                  <option value="">All datasets</option>
                  {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
                </select>
                <button className="btn btn-primary btn-sm" onClick={() => triggerDvcPull(dvcPullLeaf)} disabled={dvcRunning || ghNotConfigured || isOperationActive}>
                  Pull
                </button>
              </div>
            </div>

            {/* DVC Push All */}
            <div className="card">
              <div className="card-header"><div><div className="card-label">DVC Push</div><div className="card-title">Sync to Remote</div></div></div>
              <p style={{ fontSize: 13, color: '#64748b', marginBottom: 12, lineHeight: 1.5 }}>Push all tracked datasets to DVC remote (Google Drive). Runs via GitHub Actions.</p>
              <button className="btn btn-primary btn-sm" onClick={triggerDvcPushAll} disabled={dvcRunning || ghNotConfigured || isOperationActive}>
                Push All
              </button>
            </div>

            {/* Export Data */}
            <div className="card">
              <div className="card-header"><div><div className="card-label">Export</div><div className="card-title">Predictions Snapshot</div></div></div>
              <p style={{ fontSize: 13, color: '#64748b', marginBottom: 12, lineHeight: 1.5 }}>Export all prediction records as JSON and push to DVC.</p>
              <button className="btn btn-primary btn-sm" onClick={triggerExportData} disabled={dvcRunning || ghNotConfigured || isOperationActive}>
                Export Data
              </button>
            </div>
          </div>

          {/* Log output */}
          {dvcLog.length > 0 && (
            <div className="dvc-panel" style={{ marginBottom: 20 }}>
              <h3 style={{ marginBottom: 10 }}>Operation Log</h3>
              <div className="dvc-log">{dvcLog.map((line, i) => <div key={i}>{line}</div>)}</div>
            </div>
          )}

          {/* DVC Tracked Datasets */}
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header">
              <div><div className="card-label">DVC Remote</div><div className="card-title">Tracked Datasets</div></div>
              <button className="btn btn-sm" onClick={fetchTrackedDatasets} disabled={dvcDatasetsLoading}>
                {dvcDatasetsLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Refresh'}
              </button>
            </div>
            {dvcDatasets.length > 0 ? (
              <table>
                <thead><tr><th>Dataset</th><th>Classes</th><th>Images</th><th>Size</th><th>Version</th><th>Updated</th><th>Per-class</th></tr></thead>
                <tbody>
                  {dvcDatasets.map(ds => (
                    <tr key={ds.name}>
                      <td><strong style={{ color: '#121c28' }}>{ds.name}</strong></td>
                      <td>{ds.num_classes != null ? ds.num_classes : '—'}</td>
                      <td>{ds.nfiles != null ? ds.nfiles.toLocaleString() : '—'}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{ds.size != null ? formatBytes(ds.size) : '—'}</td>
                      <td style={{ fontSize: 11, color: '#94a3b8', fontFamily: 'monospace' }}>{ds.md5 ? ds.md5.slice(0, 8) + '…' : '—'}</td>
                      <td style={{ fontSize: 12, color: '#94a3b8' }}>{ds.lastUpdated ? formatDateTime(ds.lastUpdated) : '—'}</td>
                      <td>
                        {ds.classes ? (
                          <details>
                            <summary style={{ cursor: 'pointer', color: '#3b82f6', fontSize: 11 }}>View</summary>
                            <table style={{ fontSize: 11, marginTop: 2, borderCollapse: 'collapse' }}>
                              <tbody>
                                {Object.entries(ds.classes).map(([cls, info]) => (
                                  <tr key={cls} style={{ borderBottom: '1px solid #f1f5f9' }}>
                                    <td style={{ padding: '1px 8px 1px 0', color: '#475569' }}>{cls}</td>
                                    <td style={{ padding: '1px 0', textAlign: 'right', color: '#64748b' }}>{typeof info === 'object' ? info.count : info}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </details>
                        ) : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : <div className="empty-state"><p>{dvcDatasetsLoading ? 'Loading…' : 'No tracked datasets yet. Run a DVC Pull or Push to populate.'}</p></div>}
            {dvcDatasetsSource && <div style={{ fontSize: 11, color: '#94a3b8', padding: '6px 16px' }}>Source: {dvcDatasetsSource === 'db' ? 'DVC operations history' : 'GitHub .dvc files'}</div>}
          </div>

          {/* Operations History */}
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">History</div><div className="card-title">All DVC Operations</div></div>
              <button className="btn btn-sm" onClick={loadDvcOperations}>Refresh</button>
            </div>
            {dvcOps.length > 0 ? (
              <div className="table-wrapper">
                <table>
                  <thead><tr><th>Operation</th><th>Dataset</th><th>Source</th><th>Status</th><th>Details</th><th>Started</th><th>Actions</th></tr></thead>
                  <tbody>
                    {dvcOps.map(op => (
                      <tr key={op.id}>
                        <td><span className="badge">{op.operation}</span></td>
                        <td><strong style={{ color: '#121c28' }}>{op.leaf_type}</strong></td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{op.source || '—'}</td>
                        <td><StatusBadge status={op.status} /></td>
                        <td style={{ fontSize: 12, color: '#64748b', maxWidth: 320 }}>
                          {op.metadata?.file_count != null && <span>{op.metadata.file_count} files</span>}
                          {op.metadata?.total_size != null && <span style={{ marginLeft: 8 }}>{formatBytes(op.metadata.total_size)}</span>}
                          {op.metadata?.num_classes != null && <span style={{ marginLeft: 8 }}>{op.metadata.num_classes} classes</span>}
                          {op.metadata?.datasets && (
                            <details style={{ marginTop: 4 }}>
                              <summary style={{ cursor: 'pointer', color: '#3b82f6', fontSize: 11 }}>Dataset breakdown</summary>
                              {Object.entries(op.metadata.datasets).map(([dsName, ds]) => (
                                <div key={dsName} style={{ marginTop: 4, paddingLeft: 8, borderLeft: '2px solid #e2e8f0' }}>
                                  <div style={{ fontWeight: 600, color: '#334155' }}>{dsName}</div>
                                  <div style={{ fontSize: 11, color: '#94a3b8' }}>
                                    {ds.file_count} images &middot; {ds.num_classes} classes &middot; {formatBytes(ds.total_size)}
                                    {ds.dvc_md5 && <span> &middot; md5: {ds.dvc_md5.slice(0, 8)}&hellip;</span>}
                                  </div>
                                  {ds.classes && (
                                    <table style={{ fontSize: 11, marginTop: 2, borderCollapse: 'collapse', width: '100%' }}>
                                      <tbody>
                                        {Object.entries(ds.classes).map(([cls, info]) => (
                                          <tr key={cls} style={{ borderBottom: '1px solid #f1f5f9' }}>
                                            <td style={{ padding: '1px 6px 1px 0', color: '#475569' }}>{cls}</td>
                                            <td style={{ padding: '1px 0', textAlign: 'right', color: '#64748b' }}>{info.count}</td>
                                          </tr>
                                        ))}
                                      </tbody>
                                    </table>
                                  )}
                                </div>
                              ))}
                            </details>
                          )}
                          {op.metadata?.classes && !op.metadata?.datasets && (
                            <details style={{ marginTop: 4 }}>
                              <summary style={{ cursor: 'pointer', color: '#3b82f6', fontSize: 11 }}>Per-class breakdown</summary>
                              <table style={{ fontSize: 11, marginTop: 2, borderCollapse: 'collapse', width: '100%' }}>
                                <tbody>
                                  {Object.entries(op.metadata.classes).map(([cls, info]) => (
                                    <tr key={cls} style={{ borderBottom: '1px solid #f1f5f9' }}>
                                      <td style={{ padding: '1px 6px 1px 0', color: '#475569' }}>{cls}</td>
                                      <td style={{ padding: '1px 0', textAlign: 'right', color: '#64748b' }}>{typeof info === 'object' ? info.count : info}</td>
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            </details>
                          )}
                          {op.error_message && <div style={{ color: '#ef4444', fontSize: 11 }}>{op.error_message}</div>}
                        </td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{formatDateTime(op.started_at)}</td>
                        <td>
                          <div style={{ display: 'flex', gap: 5 }}>
                            {op.status === 'staged' && <button className="btn btn-sm btn-primary" onClick={() => triggerDvcPush(op)} disabled={isOperationActive}>Push to DVC</button>}
                            {op.status === 'staged' && <button className="btn btn-sm btn-danger" onClick={() => setConfirmAction({
                              title: 'Discard', message: `Discard staged data for "${op.leaf_type}"?`, danger: true, confirmLabel: 'Discard',
                              onConfirm: () => { setConfirmAction(null); discardStaged(op) }
                            })}>Discard</button>}
                            {op.github_run_url && <a href={op.github_run_url} target="_blank" rel="noopener noreferrer" className="btn btn-sm">View Run</a>}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <div className="empty-state"><p>No DVC operations yet. Use the Stage Data tab or buttons above to start.</p></div>}
          </div>
        </div>
      )}

      {/* ── Prediction Data Tab ── */}
      {dtab === 'Prediction Data' && (
        <div>
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header"><div><div className="card-label">User Predictions</div><div className="card-title">Prediction Records by Leaf Type</div></div></div>
            <table>
              <thead><tr><th>Leaf Type</th><th>Total Records</th></tr></thead>
              <tbody>
                {quality.map(q => <tr key={q.name}><td><strong style={{ color: '#121c28' }}>{q.name}</strong></td><td>{q.total.toLocaleString()}</td></tr>)}
                {quality.length === 0 && <tr><td colSpan={2} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No prediction data yet</td></tr>}
              </tbody>
            </table>
          </div>

          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header"><div><div className="card-label">Export</div><div className="card-title">Download Prediction Data</div></div></div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 16 }}>Export up to 50,000 most recent prediction records from the database.</p>
            <div style={{ display: 'flex', gap: 12 }}>
              <button className="btn btn-primary" onClick={() => exportAll('csv')}>Export CSV</button>
              <button className="btn" onClick={() => exportAll('json')}>Export JSON</button>
            </div>
          </div>

          <div className="card">
            <div className="card-header" onClick={() => setShowImportCsv(v => !v)} style={{ cursor: 'pointer' }}>
              <div>
                <div className="card-label">Advanced</div>
                <div className="card-title" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  Import Predictions from CSV
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ transform: showImportCsv ? 'rotate(180deg)' : 'rotate(0deg)', transition: 'transform 0.2s' }}><path d="M6 9l6 6 6-6"/></svg>
                </div>
              </div>
            </div>
            {showImportCsv && (
              <div style={{ padding: '0 16px 16px' }}>
                <div className="alert alert-info" style={{ marginBottom: 16 }}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
                  <div>Bulk import prediction records. Required: <code>leaf_type</code>, <code>predicted_class_name</code>. Optional: <code>confidence, user_id, notes, model_version, created_at</code>.</div>
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
                {csvMsg && <div className={`alert ${csvMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>{csvMsg.text}</div>}
                {csvParsed && !csvImporting && <button className="btn btn-primary" onClick={importCSV}>Import {csvParsed.total.toLocaleString()} Records</button>}
              </div>
            )}
          </div>
        </div>
      )}

      {/* ── Storage Files Tab ── */}
      {dtab === 'Storage Files' && (
        <div>
          {/* Sub-tab nav */}
          <div style={{ display: 'flex', gap: 0, marginBottom: 16, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
            {['Datasets', 'Prediction Images'].map(t => (
              <button key={t} onClick={() => {
                setStorageSubTab(t)
                if (t === 'Prediction Images' && predImages.length === 0) loadPredictionImages(true)
                if (t === 'Datasets' && storedFiles.length === 0) loadStorageFiles()
              }} style={{ padding: '8px 16px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: storageSubTab === t ? '#0284c7' : '#64748b', borderBottom: `2px solid ${storageSubTab === t ? '#0284c7' : 'transparent'}`, fontFamily: 'inherit' }}>
                {t}
              </button>
            ))}
          </div>

          {/* ── Datasets sub-tab ── */}
          {storageSubTab === 'Datasets' && (
            <div>
              <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
                {['datasets', 'models'].map(b => (
                  <button key={b} className={`btn btn-sm ${storageBucket === b ? 'btn-primary' : ''}`}
                    onClick={() => { setStorageBucket(b); setStoredFiles([]); setTimeout(() => loadStorageFiles(b), 0) }}>
                    {b}
                  </button>
                ))}
              </div>
              <div className="card">
                <div className="card-header">
                  <div><div className="card-label">Supabase Storage</div><div className="card-title">Files in &quot;{storageBucket}&quot; bucket</div></div>
                  <button className="btn btn-sm btn-primary" onClick={() => loadStorageFiles()} disabled={storageLoading}>
                    {storageLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading&hellip;</> : 'Refresh'}
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
                                <a href={supabase.storage.from(storageBucket).getPublicUrl(f.path).data.publicUrl} target="_blank" rel="noopener noreferrer" className="btn btn-sm">Download</a>
                                <button className="btn btn-sm btn-danger" onClick={() => deleteStorageFile(f)}>Delete</button>
                              </div>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                ) : <div className="empty-state"><p>No files found in &quot;{storageBucket}&quot; bucket.</p></div>}
              </div>
            </div>
          )}

          {/* ── Prediction Images sub-tab ── */}
          {storageSubTab === 'Prediction Images' && (
            <div>
              {/* Filters */}
              <div style={{ display: 'flex', gap: 12, marginBottom: 16, alignItems: 'center' }}>
                <select className="form-input" style={{ width: 200 }} value={predImgLeaf} onChange={e => { setPredImgLeaf(e.target.value); loadPredictionImages(true) }}>
                  <option value="">All leaf types</option>
                  {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
                </select>
                <button className="btn btn-sm btn-primary" onClick={() => loadPredictionImages(true)} disabled={predImagesLoading}>
                  {predImagesLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading&hellip;</> : 'Refresh'}
                </button>
                <span style={{ fontSize: 12, color: '#94a3b8' }}>{predImages.length} images loaded</span>
              </div>

              {/* Images grid */}
              {predImagesLoading && predImages.length === 0 ? (
                <div className="loading-spinner"><div className="spinner" /></div>
              ) : predImages.length > 0 ? (
                <>
                  <div className="card">
                    <div className="table-wrapper">
                      <table>
                        <thead><tr><th style={{ width: 64 }}>Preview</th><th>Label</th><th>Confidence</th><th>Leaf Type</th><th>Date</th><th>Actions</th></tr></thead>
                        <tbody>
                          {predImages.map(p => (
                            <tr key={p.id}>
                              <td>
                                {p.signedUrl ? (
                                  <img src={p.signedUrl} alt="" style={{ width: 48, height: 48, objectFit: 'cover', borderRadius: 6, cursor: 'pointer', border: '1px solid #e2e8f0' }}
                                    onClick={() => openPreview(p)} />
                                ) : (
                                  <div style={{ width: 48, height: 48, background: '#f1f5f9', borderRadius: 6, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', fontSize: 10, color: '#94a3b8' }}
                                    onClick={() => openPreview(p)}>
                                    No img
                                  </div>
                                )}
                              </td>
                              <td>
                                {editingLabel === p.id ? (
                                  <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
                                    <input className="form-input" style={{ width: 150, padding: '4px 8px', fontSize: 12 }}
                                      value={editLabelValue} onChange={e => setEditLabelValue(e.target.value)}
                                      onKeyDown={e => { if (e.key === 'Enter') savePredLabel(p.id, editLabelValue); if (e.key === 'Escape') setEditingLabel(null) }}
                                      autoFocus />
                                    <button className="btn btn-sm btn-primary" style={{ padding: '2px 8px', fontSize: 11 }}
                                      onClick={() => savePredLabel(p.id, editLabelValue)}>Save</button>
                                    <button className="btn btn-sm" style={{ padding: '2px 8px', fontSize: 11 }}
                                      onClick={() => setEditingLabel(null)}>Cancel</button>
                                  </div>
                                ) : (
                                  <span style={{ cursor: 'pointer', borderBottom: '1px dashed #94a3b8' }} title="Click to edit label"
                                    onClick={() => { setEditingLabel(p.id); setEditLabelValue(p.predicted_class_name || '') }}>
                                    {p.predicted_class_name || '—'}
                                  </span>
                                )}
                              </td>
                              <td>
                                <span style={{ fontSize: 12, color: p.confidence >= 0.8 ? '#16a34a' : p.confidence >= 0.5 ? '#f59e0b' : '#ef4444' }}>
                                  {p.confidence != null ? `${(p.confidence * 100).toFixed(1)}%` : '—'}
                                </span>
                              </td>
                              <td><span className="badge badge-primary">{p.leaf_type}</span></td>
                              <td style={{ fontSize: 12, color: '#94a3b8' }}>{p.created_at ? formatDateTime(p.created_at) : '—'}</td>
                              <td>
                                <button className="btn btn-sm" onClick={() => openPreview(p)}>Preview</button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                  {predImgHasMore && (
                    <div style={{ textAlign: 'center', marginTop: 16 }}>
                      <button className="btn btn-primary" onClick={() => loadPredictionImages(false)} disabled={predImagesLoading}>
                        {predImagesLoading ? 'Loading...' : 'Load More'}
                      </button>
                    </div>
                  )}
                </>
              ) : <div className="empty-state"><p>No prediction images found. Images appear here when users make predictions via the mobile app.</p></div>}
            </div>
          )}
        </div>
      )}

      {/* ── Image Preview Modal ── */}
      {previewImg && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', zIndex: 9999, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
          onClick={() => setPreviewImg(null)}>
          <div style={{ background: '#fff', borderRadius: 12, maxWidth: 600, maxHeight: '90vh', overflow: 'auto', padding: 20, position: 'relative' }}
            onClick={e => e.stopPropagation()}>
            <button onClick={() => setPreviewImg(null)} style={{ position: 'absolute', top: 8, right: 12, background: 'none', border: 'none', fontSize: 22, cursor: 'pointer', color: '#64748b' }}>&times;</button>
            {previewImg.url ? (
              <img src={previewImg.url} alt="Prediction" style={{ width: '100%', borderRadius: 8, marginBottom: 12 }} />
            ) : (
              <div style={{ width: '100%', height: 300, background: '#f1f5f9', borderRadius: 8, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#94a3b8', marginBottom: 12 }}>Image not available</div>
            )}
            {previewImg.prediction && (
              <div style={{ fontSize: 13, color: '#334155' }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '4px 12px' }}>
                  <strong>Label:</strong><span>{previewImg.prediction.predicted_class_name || '—'}</span>
                  <strong>Confidence:</strong><span>{previewImg.prediction.confidence != null ? `${(previewImg.prediction.confidence * 100).toFixed(1)}%` : '—'}</span>
                  <strong>Leaf Type:</strong><span>{previewImg.prediction.leaf_type}</span>
                  <strong>Date:</strong><span>{previewImg.prediction.created_at ? formatDateTime(previewImg.prediction.created_at) : '—'}</span>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )

  async function loadStorageFiles(bucket) {
    const b = bucket || storageBucket
    setStorageLoading(true)
    try {
      const { data: folders } = await supabase.storage.from(b).list('', { limit: 100 })
      const allFiles = []
      for (const folder of (folders || [])) {
        if (folder.id) { allFiles.push({ ...folder, folder: '(root)', path: folder.name }); continue }
        const { data: files } = await supabase.storage.from(b).list(folder.name, { limit: 100 })
        for (const f of (files || [])) allFiles.push({ ...f, folder: folder.name, path: `${folder.name}/${f.name}` })
      }
      setStoredFiles(allFiles)
    } catch (err) { setError('Failed to list storage: ' + err.message) }
    setStorageLoading(false)
  }

  function deleteStorageFile(f) {
    setConfirmAction({
      title: 'Delete File', message: `Permanently delete "${f.name}" from ${storageBucket}/${f.folder}?`, danger: true, confirmLabel: 'Delete',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error } = await supabase.storage.from(storageBucket).remove([f.path])
        if (error) alert('Delete failed: ' + error.message)
        else loadStorageFiles()
      }
    })
  }
}
