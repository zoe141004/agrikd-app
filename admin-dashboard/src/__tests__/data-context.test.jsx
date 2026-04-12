/**
 * DataContext integration tests
 * Tests the shared state provider that synchronises leaf types,
 * DVC datasets, GitHub connection, and the global refresh mechanism.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import React from 'react'

// ── Mock supabase with full chain support ──────────────────────────────────
let _rpcResult = { data: [], error: null }
let _registryResult = { data: [], error: null }
let _dvcOpsLeafResult = { data: [], error: null }
let _dvcOpsDatasetResult = { data: [], error: null }

function buildChain(resolveWith) {
  const chain = {
    select: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    neq: vi.fn().mockReturnThis(),
    in: vi.fn().mockReturnThis(),
    not: vi.fn().mockReturnThis(),
    is: vi.fn().mockReturnThis(),
    order: vi.fn().mockReturnThis(),
    limit: vi.fn(() => Promise.resolve(resolveWith)),
    single: vi.fn(() => Promise.resolve(resolveWith)),
  }
  // Make each method return chain for further chaining
  for (const m of ['select', 'eq', 'neq', 'in', 'not', 'is', 'order']) {
    chain[m].mockReturnValue(chain)
  }
  return chain
}

// Track which table/rpc is being called to return the right mock data
const mockSupabase = {
  rpc: vi.fn((fnName) => {
    if (fnName === 'get_leaf_type_options') return Promise.resolve(_rpcResult)
    return Promise.resolve({ data: null, error: null })
  }),
  from: vi.fn((table) => {
    if (table === 'model_registry') return buildChain(_registryResult)
    if (table === 'dvc_operations') {
      // DataContext calls dvc_operations twice:
      // 1. refreshLeafTypes: select('leaf_type').in('status',...).not(...).neq(...).limit(200)
      // 2. refreshDvcDatasets: select('leaf_type, metadata, completed_at').in('operation',...).eq('status','completed').not(...).order(...).limit(50)
      // We differentiate by what select() is called with, but since mocks are stateless,
      // return a chain that can resolve to either result based on which .limit() is called
      const chain = buildChain(_dvcOpsLeafResult)
      // Override limit to check the value — refreshLeafTypes uses limit(200), refreshDvcDatasets uses limit(50)
      chain.limit = vi.fn((n) => {
        return Promise.resolve(n >= 200 ? _dvcOpsLeafResult : _dvcOpsDatasetResult)
      })
      return chain
    }
    return buildChain({ data: [], error: null })
  }),
  auth: {
    getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
    onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
  },
}

vi.mock('../lib/supabase', () => ({ supabase: mockSupabase }))
vi.mock('../lib/helpers', async (importOriginal) => {
  const original = await importOriginal()
  return {
    ...original,
    getGitHubConfig: vi.fn(() => ({ ghToken: '', ghOwner: '', ghRepo: '', ghBranch: 'main' })),
  }
})

// Now import the component under test (must be after vi.mock)
const { DataProvider, useData } = await import('../lib/DataContext')

// ── Helper consumer component ──────────────────────────────────────────────
function ContextReader({ onValue }) {
  const ctx = useData()
  React.useEffect(() => { onValue(ctx) })
  return (
    <div>
      <span data-testid="leaf-count">{ctx.leafTypeOptions.length}</span>
      <span data-testid="dvc-count">{ctx.dvcDatasets.length}</span>
      <span data-testid="refresh-key">{ctx.refreshKey}</span>
      <span data-testid="gh-status">{ctx.ghConnectionStatus || 'null'}</span>
      <button onClick={ctx.triggerRefresh} data-testid="refresh-btn">Refresh</button>
    </div>
  )
}

function renderWithProvider(onValue = vi.fn()) {
  return render(
    <MemoryRouter>
      <DataProvider>
        <ContextReader onValue={onValue} />
      </DataProvider>
    </MemoryRouter>
  )
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('DataContext', () => {
  beforeEach(() => {
    _rpcResult = { data: [], error: null }
    _registryResult = { data: [], error: null }
    _dvcOpsLeafResult = { data: [], error: null }
    _dvcOpsDatasetResult = { data: [], error: null }
    vi.clearAllMocks()
  })

  it('renders provider and exposes initial context values', async () => {
    renderWithProvider()
    await waitFor(() => {
      expect(screen.getByTestId('leaf-count').textContent).toBe('0')
      expect(screen.getByTestId('dvc-count').textContent).toBe('0')
      expect(screen.getByTestId('refresh-key').textContent).toBe('0')
    })
  })

  it('throws when useData is used outside DataProvider', () => {
    function Orphan() {
      useData()
      return null
    }
    // Suppress console.error for expected error
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => render(
      <MemoryRouter><Orphan /></MemoryRouter>
    )).toThrow('useData must be used within DataProvider')
    spy.mockRestore()
  })

  it('merges leaf types from RPC, model_registry, and dvc_operations', async () => {
    _rpcResult = { data: [{ leaf_type: 'tomato' }, { leaf_type: 'burmese_grape_leaf' }], error: null }
    _registryResult = { data: [{ leaf_type: 'tomato' }, { leaf_type: 'potato' }], error: null }
    _dvcOpsLeafResult = { data: [{ leaf_type: 'cassava' }], error: null }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.leafTypeOptions).toEqual(
        expect.arrayContaining(['burmese_grape_leaf', 'cassava', 'potato', 'tomato'])
      )
      // Sorted alphabetically
      expect(latest.leafTypeOptions).toEqual([...latest.leafTypeOptions].sort())
    })
  })

  it('deduplicates leaf types from overlapping sources', async () => {
    _rpcResult = { data: [{ leaf_type: 'tomato' }], error: null }
    _registryResult = { data: [{ leaf_type: 'tomato' }], error: null }
    _dvcOpsLeafResult = { data: [{ leaf_type: 'tomato' }], error: null }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.leafTypeOptions).toEqual(['tomato'])
    })
  })

  it('tolerates partial source failures in refreshLeafTypes', async () => {
    // RPC fails, but registry and dvc succeed
    _rpcResult = Promise.reject(new Error('RPC timeout'))
    _registryResult = { data: [{ leaf_type: 'potato' }], error: null }
    _dvcOpsLeafResult = { data: [{ leaf_type: 'tomato' }], error: null }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.leafTypeOptions).toEqual(
        expect.arrayContaining(['potato', 'tomato'])
      )
    })
  })

  it('parses DVC datasets from operation metadata', async () => {
    _dvcOpsDatasetResult = {
      data: [{
        leaf_type: 'all',
        metadata: {
          datasets: {
            tomato: { file_count: 1609, total_size: '643M', num_classes: 10 },
            potato_dataset: { file_count: 3076, total_size: '726M', classes: { healthy: 1, blight: 2 } },
          },
        },
        completed_at: '2025-01-15T10:00:00Z',
      }],
      error: null,
    }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.dvcDatasets).toHaveLength(2)
      const tomato = latest.dvcDatasets.find(d => d.name === 'tomato')
      expect(tomato).toBeTruthy()
      expect(tomato.nfiles).toBe(1609)
      expect(tomato.num_classes).toBe(10)
      const potato = latest.dvcDatasets.find(d => d.name === 'potato_dataset')
      expect(potato).toBeTruthy()
      expect(potato.num_classes).toBe(2) // from Object.keys(classes).length
    })
  })

  it('prevents duplicate datasets via normalized key', async () => {
    _dvcOpsDatasetResult = {
      data: [
        {
          leaf_type: 'all',
          metadata: {
            datasets: {
              Tomato: { file_count: 10, total_size: '10M' },
            },
          },
          completed_at: '2025-01-15T10:00:00Z',
        },
        {
          leaf_type: 'all',
          metadata: {
            datasets: {
              tomato: { file_count: 20, total_size: '20M' },
            },
          },
          completed_at: '2025-01-14T10:00:00Z',
        },
      ],
      error: null,
    }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      // Should have only 1 entry (first one wins, case-insensitive dedup)
      expect(latest.dvcDatasets).toHaveLength(1)
      expect(latest.dvcDatasets[0].name).toBe('Tomato')
    })
  })

  it('increments refreshKey when triggerRefresh is called', async () => {
    renderWithProvider()
    const btn = screen.getByTestId('refresh-btn')

    expect(screen.getByTestId('refresh-key').textContent).toBe('0')

    await act(async () => { fireEvent.click(btn) })
    expect(screen.getByTestId('refresh-key').textContent).toBe('1')

    await act(async () => { fireEvent.click(btn) })
    expect(screen.getByTestId('refresh-key').textContent).toBe('2')
  })

  it('shows not_configured when GitHub config is missing', async () => {
    renderWithProvider()
    await waitFor(() => {
      expect(screen.getByTestId('gh-status').textContent).toBe('not_configured')
    })
  })

  it('sets dvcDatasetsSource to db when DB returns results', async () => {
    _dvcOpsDatasetResult = {
      data: [{
        leaf_type: 'tomato',
        metadata: { file_count: 100, total_size: '50M' },
        completed_at: '2025-01-15T10:00:00Z',
      }],
      error: null,
    }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.dvcDatasetsSource).toBe('db')
    })
  })

  it('auto-adds dvcDataset names to leafTypeOptions', async () => {
    // No leaf types from RPC/registry, but dvcDatasets has entries
    _dvcOpsDatasetResult = {
      data: [{
        leaf_type: 'all',
        metadata: {
          datasets: {
            mango: { file_count: 50, total_size: '30M' },
          },
        },
        completed_at: '2025-01-15T10:00:00Z',
      }],
      error: null,
    }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.leafTypeOptions).toContain('mango')
    })
  })

  it('skips leaf_type "all" in dvcDatasets single-dataset fallback', async () => {
    _dvcOpsDatasetResult = {
      data: [{
        leaf_type: 'all',
        metadata: { file_count: 500, total_size: '1G' },
        completed_at: '2025-01-15T10:00:00Z',
      }],
      error: null,
    }

    const onValue = vi.fn()
    renderWithProvider(onValue)

    // Wait for loading to finish
    await waitFor(() => {
      const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
      expect(latest.dvcDatasetsLoading).toBe(false)
    })

    // "all" should NOT appear as a dataset
    const latest = onValue.mock.calls[onValue.mock.calls.length - 1][0]
    expect(latest.dvcDatasets.every(d => d.name !== 'all')).toBe(true)
  })
})
