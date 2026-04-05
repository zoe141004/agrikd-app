import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

// ── Chainable Supabase query mock builder ────────────────────────────────────
// Each from() call returns a thenable chain that resolves to the configured value.
function createChainable(resolveValue) {
  const chain = {}
  const methods = ['select', 'eq', 'gte', 'lte', 'order', 'range', 'limit', 'single', 'head']
  methods.forEach((m) => {
    chain[m] = vi.fn(() => chain)
  })
  // Make the chain thenable so `await supabase.from(...).select(...)...` works
  chain.then = (resolve, reject) =>
    Promise.resolve(resolveValue).then(resolve, reject)
  return chain
}

// ── Mock Supabase client ─────────────────────────────────────────────────────
const mockRpc = vi.fn()
const mockFrom = vi.fn()
const mockGetSession = vi.fn()
const mockOnAuthStateChange = vi.fn(() => ({
  data: { subscription: { unsubscribe: vi.fn() } },
}))

vi.mock('../lib/supabase', () => ({
  supabase: {
    auth: {
      getSession: (...args) => mockGetSession(...args),
      onAuthStateChange: (...args) => mockOnAuthStateChange(...args),
      signInWithPassword: vi.fn(() => Promise.resolve({ error: null })),
      signOut: vi.fn(() => Promise.resolve()),
      getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
    },
    from: (...args) => mockFrom(...args),
    rpc: (...args) => mockRpc(...args),
    storage: {
      from: () => ({
        upload: vi.fn(() => Promise.resolve({ data: null, error: null })),
        getPublicUrl: vi.fn(() => ({ data: { publicUrl: '' } })),
      }),
      createBucket: vi.fn(() => Promise.resolve({ error: null })),
    },
  },
}))

// ── Mock recharts (avoid canvas/SVG issues in jsdom) ─────────────────────────
vi.mock('recharts', () => ({
  AreaChart: ({ children }) => children,
  Area: () => null,
  BarChart: ({ children }) => children,
  Bar: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
  ResponsiveContainer: ({ children }) => children,
  Cell: () => null,
  PieChart: ({ children }) => children,
  Pie: () => null,
  Legend: () => null,
}))

// ── Import components after mocks are set up ─────────────────────────────────
import DashboardPage from '../pages/DashboardPage'
import PredictionsPage from '../pages/PredictionsPage'
import ModelReportsPage from '../pages/ModelReportsPage'
import ModelsPage from '../pages/ModelsPage'

// ── Helpers ──────────────────────────────────────────────────────────────────
function renderPage(Component) {
  return render(
    <MemoryRouter>
      <Component />
    </MemoryRouter>,
  )
}

// ── Shared mock data ─────────────────────────────────────────────────────────
const MOCK_PREDICTIONS = [
  {
    id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    user_id: 'user-001',
    leaf_type: 'tomato',
    predicted_class_name: 'Tomato___Healthy',
    confidence: 0.92,
    created_at: '2026-03-20T10:00:00Z',
    model_version: '1.0.0',
    notes: null,
  },
  {
    id: 'b2c3d4e5-f6a7-8901-bcde-f12345678901',
    user_id: 'user-002',
    leaf_type: 'burmese_grape_leaf',
    predicted_class_name: 'Anthracnose',
    confidence: 0.74,
    created_at: '2026-03-19T14:30:00Z',
    model_version: '1.0.0',
    notes: 'Field sample',
  },
  {
    id: 'c3d4e5f6-a7b8-9012-cdef-123456789012',
    user_id: 'user-001',
    leaf_type: 'tomato',
    predicted_class_name: 'Tomato___Early_Blight',
    confidence: 0.45,
    created_at: '2026-03-18T08:15:00Z',
    model_version: '1.0.0',
    notes: null,
  },
]

const MOCK_REPORTS = [
  {
    id: 'rpt-001',
    prediction_id: MOCK_PREDICTIONS[0].id,
    user_id: 'user-001',
    leaf_type: 'tomato',
    model_version: '1.0.0',
    reason: 'Model predicted healthy but leaf clearly has spots',
    created_at: '2026-03-21T11:00:00Z',
    predictions: {
      leaf_type: 'tomato',
      predicted_class_name: 'Tomato___Healthy',
    },
  },
  {
    id: 'rpt-002',
    prediction_id: MOCK_PREDICTIONS[2].id,
    user_id: 'user-002',
    leaf_type: 'burmese_grape_leaf',
    model_version: '1.0.0',
    reason: 'Wrong disease class detected',
    created_at: '2026-03-20T09:00:00Z',
    predictions: {
      leaf_type: 'burmese_grape_leaf',
      predicted_class_name: 'Anthracnose',
    },
  },
]

const MOCK_BENCHMARKS = [
  {
    id: 'bench-1',
    leaf_type: 'tomato',
    version: '1.0.0',
    format: 'pytorch',
    accuracy: 87.2,
    precision_macro: 0.872,
    recall_macro: 0.871,
    f1_macro: 0.871,
    latency_ms: 45.2,
    model_size_mb: 8.7,
    created_at: '2026-03-15T10:00:00Z',
  },
  {
    id: 'bench-2',
    leaf_type: 'tomato',
    version: '1.0.0',
    format: 'onnx',
    accuracy: 87.2,
    precision_macro: 0.872,
    recall_macro: 0.871,
    f1_macro: 0.871,
    latency_ms: 12.3,
    model_size_mb: 3.8,
    created_at: '2026-03-15T10:01:00Z',
  },
  {
    id: 'bench-3',
    leaf_type: 'tomato',
    version: '1.0.0',
    format: 'tflite_float16',
    accuracy: 87.1,
    precision_macro: 0.871,
    recall_macro: 0.870,
    f1_macro: 0.870,
    latency_ms: 8.5,
    model_size_mb: 0.95,
    created_at: '2026-03-15T10:02:00Z',
  },
  {
    id: 'bench-4',
    leaf_type: 'tomato',
    version: '2.0.0',
    format: 'pytorch',
    accuracy: 89.5,
    precision_macro: 0.895,
    recall_macro: 0.894,
    f1_macro: 0.894,
    latency_ms: 44.0,
    model_size_mb: 8.7,
    created_at: '2026-03-20T10:00:00Z',
  },
  {
    id: 'bench-5',
    leaf_type: 'tomato',
    version: '2.0.0',
    format: 'tflite_float16',
    accuracy: 89.3,
    precision_macro: 0.893,
    recall_macro: 0.892,
    f1_macro: 0.892,
    latency_ms: 7.8,
    model_size_mb: 0.95,
    created_at: '2026-03-20T10:01:00Z',
  },
]

const MOCK_MODELS = [
  {
    id: 'model-1',
    leaf_type: 'tomato',
    display_name: 'Tomato Disease Model',
    version: '1.0.0',
    description: 'MobileNetV2 student model for tomato diseases',
    num_classes: 10,
    status: 'active',
    is_active: true,
    created_at: '2026-03-01T00:00:00Z',
  },
]

// ── Tests ────────────────────────────────────────────────────────────────────

describe('Group 1: Dashboard RPC Integration', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    // Mock RPC calls with argument-based routing
    mockRpc.mockImplementation((fnName) => {
      switch (fnName) {
        case 'get_dashboard_stats':
          return Promise.resolve({
            data: { total: 150, unique_users: 25, avg_confidence: 0.87 },
          })
        case 'get_disease_distribution':
          return Promise.resolve({
            data: [
              { name: 'Healthy', count: 50, type: 'tomato' },
              { name: 'Early Blight', count: 30, type: 'tomato' },
            ],
          })
        case 'get_leaf_type_options':
          return Promise.resolve({
            data: [{ leaf_type: 'tomato' }, { leaf_type: 'burmese_grape_leaf' }],
          })
        default:
          return Promise.resolve({ data: null })
      }
    })

    // Mock from() calls with table-based routing
    mockFrom.mockImplementation((tableName) => {
      switch (tableName) {
        case 'model_registry':
          return createChainable({ count: 2, data: null })
        case 'predictions':
          return createChainable({
            data: MOCK_PREDICTIONS.slice(0, 2),
          })
        default:
          return createChainable({ data: null })
      }
    })
  })

  it('shows stats from RPC in stat cards', async () => {
    renderPage(DashboardPage)

    // Wait for loading to finish and verify stat card values
    await waitFor(() => {
      expect(screen.getByText('150')).toBeInTheDocument()
    })

    // Users with predictions = 25
    expect(screen.getByText('25')).toBeInTheDocument()

    // Registered models = 2 (from model_registry count)
    expect(screen.getByText('2')).toBeInTheDocument()

    // Verify stat card labels are present
    expect(screen.getByText('Total Predictions')).toBeInTheDocument()
    expect(screen.getByText('Users with Predictions')).toBeInTheDocument()
    expect(screen.getByText('Registered Models')).toBeInTheDocument()

    // Verify RPCs were called with correct arguments
    expect(mockRpc).toHaveBeenCalledWith('get_dashboard_stats', { p_leaf_type: null })
    expect(mockRpc).toHaveBeenCalledWith('get_disease_distribution', { p_leaf_type: null })
    expect(mockRpc).toHaveBeenCalledWith('get_leaf_type_options')

    // Verify from() was called for model_registry and predictions
    expect(mockFrom).toHaveBeenCalledWith('model_registry')
    expect(mockFrom).toHaveBeenCalledWith('predictions')
  })

  it('renders disease distribution chart data', async () => {
    renderPage(DashboardPage)

    await waitFor(() => {
      expect(screen.getByText('Top Detected Diseases')).toBeInTheDocument()
    })

    // Verify page sections are rendered
    expect(screen.getByText('Daily Scans — Last 30 Days')).toBeInTheDocument()
    expect(screen.getByText('Dataset Split')).toBeInTheDocument()
  })

  it('renders recent predictions table', async () => {
    renderPage(DashboardPage)

    await waitFor(() => {
      expect(screen.getByText('Latest Predictions')).toBeInTheDocument()
    })

    // Table should show recent prediction data
    // leaf_type badge
    expect(screen.getAllByText('tomato').length).toBeGreaterThanOrEqual(1)
    // cleanLabel('Tomato___Healthy') = 'Healthy'
    expect(screen.getAllByText('Healthy').length).toBeGreaterThanOrEqual(1)
  })

  it('renders leaf type filter dropdown with options', async () => {
    renderPage(DashboardPage)

    await waitFor(() => {
      expect(screen.getByText('All Leaf Types')).toBeInTheDocument()
    })

    // Verify leaf type options from RPC are rendered
    const select = screen.getByDisplayValue('All Leaf Types')
    expect(select).toBeInTheDocument()
  })

  it('handles RPC error gracefully without crashing', async () => {
    // Override RPCs to reject — Promise.all will reject on the first failure
    mockRpc.mockImplementation(() => {
      return Promise.reject(new Error('Database connection failed'))
    })

    // from() still returns normal chainables; Promise.all rejects before
    // awaiting them so the actual resolve values don't matter.
    mockFrom.mockImplementation(() => createChainable({ data: null, count: 0 }))

    renderPage(DashboardPage)

    // Should show error message instead of crashing
    await waitFor(() => {
      expect(screen.getByText('Database connection failed')).toBeInTheDocument()
    })

    // Page header should still be present (component didn't crash)
    expect(screen.getByText('Dashboard')).toBeInTheDocument()
  })

  it('handles empty RPC responses gracefully', async () => {
    // Override RPCs to return null/empty data
    mockRpc.mockImplementation(() => Promise.resolve({ data: null }))
    mockFrom.mockImplementation(() => createChainable({ data: null, count: 0 }))

    renderPage(DashboardPage)

    await waitFor(() => {
      expect(screen.getByText('Total Predictions')).toBeInTheDocument()
    })

    // Stats should show zero/empty values
    expect(screen.getByText('No predictions yet')).toBeInTheDocument()
  })
})

describe('Group 2: Predictions Page', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mockRpc.mockImplementation((fnName) => {
      switch (fnName) {
        case 'get_dashboard_stats':
          return Promise.resolve({
            data: {
              total: 3,
              unique_users: 2,
              avg_confidence: 0.703,
              high_confidence_count: 1,
              low_confidence_count: 1,
            },
          })
        case 'get_disease_distribution':
          return Promise.resolve({
            data: [
              { name: 'Healthy', count: 1, type: 'tomato' },
              { name: 'Anthracnose', count: 1, type: 'burmese_grape_leaf' },
              { name: 'Early Blight', count: 1, type: 'tomato' },
            ],
          })
        default:
          return Promise.resolve({ data: null })
      }
    })

    mockFrom.mockImplementation((tableName) => {
      if (tableName === 'predictions') {
        return createChainable({
          data: MOCK_PREDICTIONS,
          count: 3,
        })
      }
      return createChainable({ data: null })
    })
  })

  it('renders table with prediction data', async () => {
    renderPage(PredictionsPage)

    await waitFor(() => {
      expect(screen.getByText('Predictions')).toBeInTheDocument()
    })

    // Verify page header
    expect(
      screen.getByText('Browse and export all leaf disease prediction records'),
    ).toBeInTheDocument()

    // Wait for table to load with data
    await waitFor(() => {
      // Truncated ID: 'a1b2c3d4'.slice(0,8) → 'a1b2c3d4'
      expect(screen.getByText(/a1b2c3d4/)).toBeInTheDocument()
    })

    // Verify leaf type badges
    expect(screen.getAllByText('tomato').length).toBeGreaterThanOrEqual(1)
    expect(
      screen.getAllByText('burmese_grape_leaf').length,
    ).toBeGreaterThanOrEqual(1)

    // Verify disease names (cleaned labels)
    // cleanLabel('Tomato___Healthy') → 'Healthy'
    expect(screen.getAllByText('Healthy').length).toBeGreaterThanOrEqual(1)
    // cleanLabel('Anthracnose') → 'Anthracnose'
    expect(screen.getByText('Anthracnose')).toBeInTheDocument()

    // Verify pagination info
    expect(screen.getByText(/Showing 1–3 of 3 records/)).toBeInTheDocument()
  })

  it('renders summary stats from RPC', async () => {
    renderPage(PredictionsPage)

    await waitFor(() => {
      expect(screen.getByText('Total Records')).toBeInTheDocument()
    })

    // Verify stat cards
    expect(screen.getByText('Unique Users')).toBeInTheDocument()
  })

  it('shows "No predictions found" for empty data', async () => {
    // Override mocks for empty state
    mockFrom.mockImplementation(() =>
      createChainable({ data: [], count: 0 }),
    )
    mockRpc.mockImplementation(() => Promise.resolve({ data: null }))

    renderPage(PredictionsPage)

    await waitFor(() => {
      expect(screen.getByText('No predictions found')).toBeInTheDocument()
    })

    // Pagination should reflect zero records
    expect(screen.getByText(/Showing 0–0 of 0 records/)).toBeInTheDocument()
  })

  it('shows filter controls', async () => {
    renderPage(PredictionsPage)

    await waitFor(() => {
      expect(screen.getByText('Predictions')).toBeInTheDocument()
    })

    // Verify filter dropdowns exist
    expect(screen.getByText('All Leaf Types')).toBeInTheDocument()

    // Verify export buttons
    expect(screen.getByText('Export CSV')).toBeInTheDocument()
    expect(screen.getByText('Export JSON')).toBeInTheDocument()
  })

  it('calls supabase.from with correct table and chain methods', async () => {
    renderPage(PredictionsPage)

    await waitFor(() => {
      expect(mockFrom).toHaveBeenCalledWith('predictions')
    })

    // Verify RPCs are also called for summary stats
    expect(mockRpc).toHaveBeenCalledWith('get_dashboard_stats', {
      p_leaf_type: null,
    })
    expect(mockRpc).toHaveBeenCalledWith('get_disease_distribution', {
      p_leaf_type: null,
    })
  })
})

describe('Group 3: Model Reports Page', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mockFrom.mockImplementation((tableName) => {
      if (tableName === 'model_reports') {
        return createChainable({ data: MOCK_REPORTS, error: null })
      }
      return createChainable({ data: null, error: null })
    })

    mockRpc.mockImplementation(() => Promise.resolve({ data: null }))
  })

  it('renders page header and report rows', async () => {
    renderPage(ModelReportsPage)

    // Page header
    await waitFor(() => {
      expect(screen.getByText('Model Reports')).toBeInTheDocument()
    })
    expect(
      screen.getByText(
        'User-submitted reports of incorrect model predictions',
      ),
    ).toBeInTheDocument()

    // Wait for reports to load
    await waitFor(() => {
      // Report reasons should be visible
      expect(
        screen.getByText(
          'Model predicted healthy but leaf clearly has spots',
        ),
      ).toBeInTheDocument()
    })

    // Verify second report reason
    expect(
      screen.getByText('Wrong disease class detected'),
    ).toBeInTheDocument()

    // Verify leaf type badges
    expect(screen.getAllByText('tomato').length).toBeGreaterThanOrEqual(1)
    expect(
      screen.getAllByText('burmese_grape_leaf').length,
    ).toBeGreaterThanOrEqual(1)

    // Verify model version badges: "v1.0.0"
    expect(screen.getAllByText('v1.0.0').length).toBeGreaterThanOrEqual(1)

    // Verify prediction details from joined data
    // cleanLabel('Tomato___Healthy') → 'Healthy'
    expect(screen.getAllByText('Healthy').length).toBeGreaterThanOrEqual(1)

    // Verify report count indicator
    expect(screen.getByText('2 reports')).toBeInTheDocument()

    // Verify from() was called with correct table
    expect(mockFrom).toHaveBeenCalledWith('model_reports')
  })

  it('shows version stats summary when unfiltered', async () => {
    renderPage(ModelReportsPage)

    await waitFor(() => {
      expect(screen.getByText('Reports by version:')).toBeInTheDocument()
    })

    // The stats aggregate reports per "leaf_type vVersion" key
    // v1.0.0 appears in stats summary AND report table rows, so use getAllByText
    expect(screen.getAllByText(/v1\.0\.0/).length).toBeGreaterThanOrEqual(1)
  })

  it('shows table headers for all columns', async () => {
    renderPage(ModelReportsPage)

    await waitFor(() => {
      expect(screen.getByText('Model Reports')).toBeInTheDocument()
    })

    await waitFor(() => {
      expect(screen.getByText('Leaf Type')).toBeInTheDocument()
    })

    expect(screen.getByText('Model Version')).toBeInTheDocument()
    expect(screen.getByText('Prediction')).toBeInTheDocument()
    expect(screen.getByText('Reason')).toBeInTheDocument()
    expect(screen.getByText('User')).toBeInTheDocument()
    expect(screen.getByText('Date')).toBeInTheDocument()
  })

  it('shows empty state when no reports exist', async () => {
    mockFrom.mockImplementation(() =>
      createChainable({ data: [], error: null }),
    )

    renderPage(ModelReportsPage)

    await waitFor(() => {
      expect(
        screen.getByText(
          'No reports yet. Users can report wrong predictions from the mobile app.',
        ),
      ).toBeInTheDocument()
    })

    // Report count should be "0 reports"
    expect(screen.getByText('0 reports')).toBeInTheDocument()
  })

  it('renders filter dropdowns and triggers re-query on change', async () => {
    renderPage(ModelReportsPage)

    // Wait for initial load
    await waitFor(() => {
      expect(
        screen.getByText(
          'Model predicted healthy but leaf clearly has spots',
        ),
      ).toBeInTheDocument()
    })

    // The leaf filter dropdown should have options built from report data
    const leafSelect = screen.getAllByDisplayValue('All Leaf Types')[0]
    expect(leafSelect).toBeInTheDocument()

    const versionSelect = screen.getByDisplayValue('All Versions')
    expect(versionSelect).toBeInTheDocument()

    // Record initial call count for from()
    const initialCallCount = mockFrom.mock.calls.length

    // Change the leaf filter — should trigger loadReports() again
    fireEvent.change(leafSelect, { target: { value: 'tomato' } })

    // Verify that from() is called again (re-query triggered)
    await waitFor(() => {
      expect(mockFrom.mock.calls.length).toBeGreaterThan(initialCallCount)
    })
  })

  it('handles fetch error gracefully', async () => {
    mockFrom.mockImplementation(() =>
      createChainable({ data: null, error: { message: 'Permission denied' } }),
    )

    renderPage(ModelReportsPage)

    await waitFor(() => {
      expect(screen.getByText('Permission denied')).toBeInTheDocument()
    })

    // Page should still render header
    expect(screen.getByText('Model Reports')).toBeInTheDocument()
  })
})

describe('Group 4: Models Page — Benchmarks & Registry', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mockFrom.mockImplementation((tableName) => {
      switch (tableName) {
        case 'model_registry':
          return createChainable({
            data: MOCK_MODELS,
            error: null,
          })
        case 'model_benchmarks':
          return createChainable({
            data: MOCK_BENCHMARKS,
            error: null,
          })
        case 'model_versions':
          return createChainable({
            data: [],
            error: null,
          })
        case 'pipeline_runs':
          return createChainable({
            data: [],
            error: null,
          })
        case 'audit_log':
          return createChainable({ data: null, error: null })
        default:
          return createChainable({ data: null, error: null })
      }
    })

    mockRpc.mockImplementation(() => Promise.resolve({ data: null }))
  })

  it('loads registry tab by default with models', async () => {
    renderPage(ModelsPage)

    await waitFor(() => {
      expect(screen.getByText('Model Registry')).toBeInTheDocument()
    })

    // Tab buttons should all be present
    expect(screen.getByRole('button', { name: 'Registry' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Benchmarks' })).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Upload Model' }).length).toBeGreaterThanOrEqual(1)
    expect(screen.getByRole('button', { name: 'Validate' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'OTA Deploy' })).toBeInTheDocument()
  })

  it('shows benchmark data when Benchmarks tab is clicked', async () => {
    renderPage(ModelsPage)

    // Wait for initial load
    await waitFor(() => {
      expect(screen.getByText('Model Registry')).toBeInTheDocument()
    })

    // Click the Benchmarks tab
    fireEvent.click(screen.getByText('Benchmarks'))

    // Benchmarks tab should show dataset filter and version filter
    await waitFor(() => {
      expect(screen.getByText('Dataset')).toBeInTheDocument()
    })

    expect(screen.getByText('Version')).toBeInTheDocument()
  })

  it('handles model loading error', async () => {
    mockFrom.mockImplementation(() =>
      createChainable({
        data: null,
        error: { message: 'Failed to fetch models' },
      }),
    )

    renderPage(ModelsPage)

    await waitFor(() => {
      expect(
        screen.getByText('Failed to fetch models'),
      ).toBeInTheDocument()
    })
  })
})
