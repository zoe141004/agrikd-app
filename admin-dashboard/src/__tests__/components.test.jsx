import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

import ConfirmDialog from '../components/ConfirmDialog'
import ErrorBoundary from '../components/ErrorBoundary'

// ── ConfirmDialog ───────────────────────────────────────────────────────────

describe('ConfirmDialog', () => {
  it('renders nothing when open is false', () => {
    const { container } = render(
      <ConfirmDialog open={false} title="Test" message="msg" onConfirm={() => {}} onCancel={() => {}} />,
    )
    expect(container.innerHTML).toBe('')
  })

  it('renders title and message when open', () => {
    render(
      <ConfirmDialog open={true} title="Delete item?" message="This cannot be undone." onConfirm={() => {}} onCancel={() => {}} />,
    )
    expect(screen.getByText('Delete item?')).toBeInTheDocument()
    expect(screen.getByText('This cannot be undone.')).toBeInTheDocument()
  })

  it('uses default confirmLabel "Confirm"', () => {
    render(
      <ConfirmDialog open={true} title="T" message="M" onConfirm={() => {}} onCancel={() => {}} />,
    )
    expect(screen.getByText('Confirm')).toBeInTheDocument()
  })

  it('uses custom confirmLabel', () => {
    render(
      <ConfirmDialog open={true} title="T" message="M" confirmLabel="Delete" onConfirm={() => {}} onCancel={() => {}} />,
    )
    expect(screen.getByText('Delete')).toBeInTheDocument()
  })

  it('calls onConfirm when confirm button is clicked', () => {
    const onConfirm = vi.fn()
    render(
      <ConfirmDialog open={true} title="T" message="M" onConfirm={onConfirm} onCancel={() => {}} />,
    )
    fireEvent.click(screen.getByText('Confirm'))
    expect(onConfirm).toHaveBeenCalledOnce()
  })

  it('calls onCancel when Cancel button is clicked', () => {
    const onCancel = vi.fn()
    render(
      <ConfirmDialog open={true} title="T" message="M" onConfirm={() => {}} onCancel={onCancel} />,
    )
    fireEvent.click(screen.getByText('Cancel'))
    expect(onCancel).toHaveBeenCalledOnce()
  })

  it('calls onCancel when overlay is clicked', () => {
    const onCancel = vi.fn()
    render(
      <ConfirmDialog open={true} title="T" message="M" onConfirm={() => {}} onCancel={onCancel} />,
    )
    // Click the overlay (outermost div with class modal-overlay)
    fireEvent.click(screen.getByText('T').closest('.modal-overlay'))
    expect(onCancel).toHaveBeenCalled()
  })

  it('applies btn-danger class when danger prop is true', () => {
    render(
      <ConfirmDialog open={true} title="T" message="M" danger={true} confirmLabel="Delete" onConfirm={() => {}} onCancel={() => {}} />,
    )
    const btn = screen.getByText('Delete')
    expect(btn.className).toContain('btn-danger')
  })

  it('applies btn-primary class when danger prop is false', () => {
    render(
      <ConfirmDialog open={true} title="T" message="M" danger={false} onConfirm={() => {}} onCancel={() => {}} />,
    )
    const btn = screen.getByText('Confirm')
    expect(btn.className).toContain('btn-primary')
  })
})

// ── ErrorBoundary ───────────────────────────────────────────────────────────

function BrokenChild() {
  throw new Error('Test explosion')
}

function GoodChild() {
  return <div>All good</div>
}

describe('ErrorBoundary', () => {
  it('renders children when no error', () => {
    render(
      <ErrorBoundary>
        <GoodChild />
      </ErrorBoundary>,
    )
    expect(screen.getByText('All good')).toBeInTheDocument()
  })

  it('catches errors and renders fallback UI', () => {
    // Suppress console.error from React/ErrorBoundary
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})

    render(
      <ErrorBoundary>
        <BrokenChild />
      </ErrorBoundary>,
    )

    expect(screen.getByText('Something went wrong')).toBeInTheDocument()
    expect(screen.getByText('Test explosion')).toBeInTheDocument()
    expect(screen.getByText('Reload Page')).toBeInTheDocument()

    spy.mockRestore()
  })

  it('shows default message when error has no message', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})

    function ThrowsNull() {
      throw { message: null }
    }

    render(
      <ErrorBoundary>
        <ThrowsNull />
      </ErrorBoundary>,
    )

    expect(screen.getByText('An unexpected error occurred.')).toBeInTheDocument()

    spy.mockRestore()
  })
})
