import { createContext, useContext, useState, useEffect, useCallback, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { supabase } from './supabase'
import { getGitHubConfig, validateGitHubSlugs } from './helpers'

const DataContext = createContext(null)

export function useData() {
  const ctx = useContext(DataContext)
  if (!ctx) throw new Error('useData must be used within DataProvider')
  return ctx
}

export function DataProvider({ children }) {
  // ── Leaf type options (merged from predictions RPC + model_registry + dvc_operations) ──
  const [leafTypeOptions, setLeafTypeOptions] = useState([])
  const [leafTypeLoading, setLeafTypeLoading] = useState(false)

  // ── DVC tracked datasets ──
  const [dvcDatasets, setDvcDatasets] = useState([])
  const [dvcDatasetsLoading, setDvcDatasetsLoading] = useState(false)
  const [dvcDatasetsSource, setDvcDatasetsSource] = useState(null)

  // ── GitHub connection status ──
  const [ghConnectionStatus, setGhConnectionStatus] = useState(null) // null | 'connected' | 'error'
  const [ghConnectionDetail, setGhConnectionDetail] = useState('')
  const [ghTesting, setGhTesting] = useState(false)

  // ── Refresh counter — increment to trigger re-fetch on any page ──
  const [refreshKey, setRefreshKey] = useState(0)
  const triggerRefresh = useCallback(() => setRefreshKey(k => k + 1), [])

  // Track mounted state
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => { mountedRef.current = false }
  }, [])

  // ── Load leaf type options (merged from 3 sources) ──
  const refreshLeafTypes = useCallback(async () => {
    setLeafTypeLoading(true)
    try {
      const [rpcRes, registryRes, dvcRes] = await Promise.allSettled([
        supabase.rpc('get_leaf_type_options'),
        supabase.from('model_registry').select('leaf_type').limit(200),
        supabase.from('dvc_operations')
          .select('leaf_type')
          .in('status', ['completed', 'staged'])
          .not('leaf_type', 'eq', 'all')
          .limit(200),
      ])

      const rpcLeafs = rpcRes.status === 'fulfilled'
        ? (rpcRes.value?.data || []).map(r => r.leaf_type).filter(Boolean)
        : []
      const registryLeafs = registryRes.status === 'fulfilled'
        ? [...new Set((registryRes.value?.data || []).map(r => r.leaf_type))].filter(Boolean)
        : []
      const dvcLeafs = dvcRes.status === 'fulfilled'
        ? [...new Set((dvcRes.value?.data || []).map(r => r.leaf_type))].filter(Boolean)
        : []

      const merged = [...new Set([...rpcLeafs, ...registryLeafs, ...dvcLeafs])].sort()
      if (mountedRef.current) setLeafTypeOptions(merged)
    } catch (err) {
      console.warn('Failed to load leaf type options:', err.message)
    }
    if (mountedRef.current) setLeafTypeLoading(false)
  }, [])

  // ── Load DVC tracked datasets ──
  const refreshDvcDatasets = useCallback(async () => {
    setDvcDatasetsLoading(true)
    try {
      const { data: ops } = await supabase
        .from('dvc_operations')
        .select('leaf_type, metadata, completed_at')
        .in('operation', ['pull', 'push', 'stage'])
        .eq('status', 'completed')
        .not('metadata', 'is', null)
        .order('completed_at', { ascending: false })
        .limit(50)

      if (ops && ops.length > 0) {
        // Use a unified Map keyed by normalized dataset name to prevent duplicates
        const datasetMap = new Map()
        for (const op of ops) {
          const md = op.metadata
          if (md?.datasets) {
            for (const [dsName, dsInfo] of Object.entries(md.datasets)) {
              const key = dsName.toLowerCase().trim()
              if (datasetMap.has(key)) continue
              datasetMap.set(key, {
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
          } else if (md?.file_count != null) {
            const key = (op.leaf_type || '').toLowerCase().trim()
            if (!key || datasetMap.has(key)) continue
            datasetMap.set(key, {
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
        const datasets = [...datasetMap.values()]
        if (datasets.length > 0) {
          if (mountedRef.current) {
            setDvcDatasets(datasets)
            setDvcDatasetsSource('db')
          }
          setDvcDatasetsLoading(false)
          return
        }
      }

      // Fallback: read .dvc files from GitHub repo
      const { ghToken, ghOwner, ghRepo, ghBranch } = getGitHubConfig()
      if (!ghToken || !ghOwner || !ghRepo) {
        if (mountedRef.current) {
          setDvcDatasetsSource(null)
          setDvcDatasetsLoading(false)
        }
        return
      }
      try { validateGitHubSlugs(ghOwner, ghRepo) } catch { setDvcDatasetsLoading(false); return }
      const res = await fetch(
        `https://api.github.com/repos/${ghOwner}/${ghRepo}/contents?ref=${ghBranch}`,
        { headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' } }
      )
      if (!res.ok) throw new Error(`GitHub API ${res.status}`)
      const files = await res.json()
      const dvcFiles = files.filter(f => f.name.endsWith('.dvc') && f.name.startsWith('data_'))
      const datasets = []
      for (const df of dvcFiles) {
        if (!df.download_url?.startsWith('https://raw.githubusercontent.com/')) continue
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
      if (mountedRef.current) {
        setDvcDatasets(datasets)
        setDvcDatasetsSource('github')
      }
    } catch (err) {
      console.warn('Failed to fetch tracked datasets:', err.message)
    }
    if (mountedRef.current) setDvcDatasetsLoading(false)
  }, [])

  // ── Test GitHub connection ──
  const testGitHubConnection = useCallback(async () => {
    const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
    if (!ghToken || !ghOwner || !ghRepo) {
      setGhConnectionStatus('not_configured')
      setGhConnectionDetail('GitHub not configured')
      return { ok: false, message: 'GitHub not configured' }
    }
    setGhTesting(true)
    try {
      validateGitHubSlugs(ghOwner, ghRepo)
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), 10000)
      const res = await fetch(`https://api.github.com/repos/${ghOwner}/${ghRepo}`, {
        headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' },
        signal: controller.signal,
      })
      clearTimeout(timeoutId)
      const data = await res.json()
      if (res.ok) {
        const detail = `✓ ${data.full_name} (${data.private ? 'private' : 'public'}). ${data.open_issues_count} open issues.`
        if (mountedRef.current) {
          setGhConnectionStatus('connected')
          setGhConnectionDetail(detail)
        }
        return { ok: true, message: detail }
      } else {
        const detail = `Error: ${data.message}`
        if (mountedRef.current) {
          setGhConnectionStatus('error')
          setGhConnectionDetail(detail)
        }
        return { ok: false, message: detail }
      }
    } catch (err) {
      const detail = err.name === 'AbortError' ? 'Connection timeout (10s)' : err.message
      if (mountedRef.current) {
        setGhConnectionStatus('error')
        setGhConnectionDetail(detail)
      }
      return { ok: false, message: detail }
    } finally {
      if (mountedRef.current) setGhTesting(false)
    }
  }, [])

  // Check GitHub config presence (for quick badge without API call)
  const checkGhConfigPresence = useCallback(() => {
    const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
    if (!ghToken || !ghOwner || !ghRepo) {
      setGhConnectionStatus('not_configured')
      setGhConnectionDetail('GitHub not configured')
    }
    // Don't change status if already tested — keep the real status
  }, [])

  // ── Initial load + refresh on key change ──
  useEffect(() => {
    refreshLeafTypes()
    refreshDvcDatasets()
    checkGhConfigPresence()
  }, [refreshKey, refreshLeafTypes, refreshDvcDatasets, checkGhConfigPresence])

  // ── Auto-refresh shared data on route navigation ──
  const location = useLocation()
  const prevPathRef = useRef(location.pathname)
  useEffect(() => {
    if (location.pathname !== prevPathRef.current) {
      prevPathRef.current = location.pathname
      refreshLeafTypes()
    }
  }, [location.pathname, refreshLeafTypes])

  const value = {
    // Leaf types
    leafTypeOptions,
    leafTypeLoading,
    refreshLeafTypes,

    // DVC datasets
    dvcDatasets,
    setDvcDatasets,
    dvcDatasetsLoading,
    dvcDatasetsSource,
    refreshDvcDatasets,

    // GitHub connection
    ghConnectionStatus,
    setGhConnectionStatus,
    ghConnectionDetail,
    ghTesting,
    testGitHubConnection,
    checkGhConfigPresence,

    // Global refresh
    refreshKey,
    triggerRefresh,
  }

  return <DataContext.Provider value={value}>{children}</DataContext.Provider>
}
