#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the self-test fixture: a small C# and TypeScript shop with a feature branch full of planted defects.

.DESCRIPTION
    Creates a git repository with two commits on two branches:

        main              Initial shop application
        feature/refunds   Add refunds   (the change under review)

    The defects planted in feature/refunds, the real defects that come with them, and the one
    thing a reviewer must NOT report are listed in answer-key.json next to this script. The
    answer key is deliberately kept outside the generated repository so a reviewer cannot see it.

    Files are written with LF line endings and no BOM on every platform, so line numbers and
    diffs are identical on Windows and Linux. Recorded review results depend on that.

.PARAMETER Path
    Directory to create. Deleted first if it already exists.
.EXAMPLE
    pwsh -File tests/fixture/New-SampleRepo.ps1 -Path ./tmp/sample-repo
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Path = [System.IO.Path]::GetFullPath($Path)

function Write-Fixture {
    param([string]$RelativePath, [string]$Content)
    $full = Join-Path $Path $RelativePath
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $text = $Content.Replace("`r`n", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [System.IO.File]::WriteAllText($full, $text, $utf8NoBom)
}

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = & git -C $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join "`n")" }
}

if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Path | Out-Null

Invoke-FixtureGit @('init', '-q', '-b', 'main')
# A throwaway repository with a fake identity: never sign as the real user, never convert line endings.
Invoke-FixtureGit @('config', 'user.email', 'dev@example.com')
Invoke-FixtureGit @('config', 'user.name', 'Sample Dev')
Invoke-FixtureGit @('config', 'core.autocrlf', 'false')
Invoke-FixtureGit @('config', 'commit.gpgsign', 'false')

# ---------------------------------------------------------------- main

Write-Fixture 'src/Shop.Api/Models/Order.cs' @'
namespace Shop.Api.Models;

public class Order
{
    public int Id { get; set; }
    public string CustomerEmail { get; set; } = "";
    public decimal Total { get; set; }
    public string Status { get; set; } = "Pending";
}
'@

Write-Fixture 'src/Shop.Api/Services/PaymentService.cs' @'
using Shop.Api.Models;

namespace Shop.Api.Services;

public class PaymentService
{
    private readonly IPaymentProvider _provider;

    public PaymentService(IPaymentProvider provider) => _provider = provider;

    public async Task<bool> CaptureAsync(Order order, CancellationToken ct)
    {
        var result = await _provider.ChargeAsync(order.Id, order.Total, ct);
        return result.Succeeded;
    }
}
'@

Write-Fixture 'src/Shop.Api/Data/OrderRepository.cs' @'
using Microsoft.EntityFrameworkCore;
using Shop.Api.Models;

namespace Shop.Api.Data;

public class OrderRepository
{
    private readonly ShopContext _db;

    public OrderRepository(ShopContext db) => _db = db;

    public async Task<Order?> FindAsync(int id, CancellationToken ct)
        => await _db.Orders.AsNoTracking().FirstOrDefaultAsync(o => o.Id == id, ct);

    public async Task<List<Order>> SearchAsync(string status, CancellationToken ct)
        => await _db.Orders.Where(o => o.Status == status).ToListAsync(ct);
}
'@

Write-Fixture 'src/Shop.Api/Controllers/OrdersController.cs' @'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Shop.Api.Data;
using Shop.Api.Services;

namespace Shop.Api.Controllers;

[ApiController]
[Route("api/orders")]
[Authorize]
public class OrdersController : ControllerBase
{
    private readonly OrderRepository _orders;
    private readonly PaymentService _payments;

    public OrdersController(OrderRepository orders, PaymentService payments)
    {
        _orders = orders;
        _payments = payments;
    }

    [HttpPost("{id:int}/capture")]
    public async Task<IActionResult> Capture(int id, CancellationToken ct)
    {
        var order = await _orders.FindAsync(id, ct);
        if (order is null) return NotFound();
        var ok = await _payments.CaptureAsync(order, ct);
        return ok ? Ok(order) : Problem("Capture failed");
    }
}
'@

Write-Fixture 'web/src/api/orders.ts' @'
export interface Order {
  id: number;
  customerEmail: string;
  total: number;
  status: string;
}

export async function captureOrder(id: number): Promise<Order> {
  const res = await fetch(`/api/orders/${id}/capture`, { method: "POST" });
  if (!res.ok) throw new Error(`Capture failed: ${res.status}`);
  return res.json();
}
'@

Write-Fixture 'web/src/pages/OrderPage.tsx' @'
import { Order, captureOrder } from "../api/orders";

export function OrderSummary({ order }: { order: Order }) {
  return (
    <div>
      <span>{order.customerEmail}</span>
      <span>{order.status}</span>
      <button onClick={() => captureOrder(order.id)}>Capture</button>
    </div>
  );
}
'@

Write-Fixture 'web/package-lock.json' '{ "name": "web", "lockfileVersion": 3, "packages": {} }'

Write-Fixture 'src/Shop.Api/Migrations/20260101000000_Init.Designer.cs' @'
// <auto-generated />
namespace Shop.Api.Migrations;
public partial class Init { public const string Version = "1"; }
'@

Write-Fixture 'README.md' @'
# Shop

Sample application.
'@

Invoke-FixtureGit @('add', '-A')
Invoke-FixtureGit @('commit', '-q', '-m', 'Initial shop application')

# ---------------------------------------------------------------- feature/refunds

Invoke-FixtureGit @('checkout', '-q', '-b', 'feature/refunds')

Write-Fixture 'src/Shop.Api/Models/Order.cs' @'
namespace Shop.Api.Models;

public enum OrderStatus
{
    Pending,
    Captured,
    Refunded,
    Cancelled
}

public class Order
{
    public int Id { get; set; }
    public string CustomerEmail { get; set; } = "";
    public decimal Total { get; set; }
    public OrderStatus Status { get; set; } = OrderStatus.Pending;
    public decimal RefundedAmount { get; set; }
}
'@

Write-Fixture 'src/Shop.Api/Services/PaymentService.cs' @'
using Shop.Api.Models;

namespace Shop.Api.Services;

public class PaymentService
{
    private readonly IPaymentProvider _provider;
    private readonly IAuditLog _audit;

    public PaymentService(IPaymentProvider provider, IAuditLog audit)
    {
        _provider = provider;
        _audit = audit;
    }

    public async Task<bool> CaptureAsync(Order order, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var result = await _provider.ChargeAsync(order.Id, order.Total, ct);
                if (result.Succeeded)
                {
                    RecordAudit(order, "captured");
                    return true;
                }
            }
            catch (Exception)
            {
                await Task.Delay(500);
            }
        }

        return false;
    }

    public async Task<bool> RefundAsync(Order order, decimal amount)
    {
        var result = await _provider.RefundAsync(order.Id, amount, CancellationToken.None);
        order.RefundedAmount += amount;
        return result.Succeeded;
    }

    private async void RecordAudit(Order order, string action)
    {
        await _audit.WriteAsync($"order {order.Id}: {action}");
    }
}
'@

Write-Fixture 'src/Shop.Api/Data/OrderRepository.cs' @'
using Microsoft.EntityFrameworkCore;
using Shop.Api.Models;

namespace Shop.Api.Data;

public class OrderRepository
{
    private readonly ShopContext _db;
    private static readonly Dictionary<string, OrderStatus> StatusMap = new()
    {
        ["pending"] = OrderStatus.Pending,
        ["captured"] = OrderStatus.Captured
    };

    public OrderRepository(ShopContext db) => _db = db;

    public async Task<Order?> FindAsync(int id, CancellationToken ct)
        => await _db.Orders.AsNoTracking().FirstOrDefaultAsync(o => o.Id == id, ct);

    public async Task<List<Order>> SearchAsync(string status, CancellationToken ct)
    {
        var mapped = StatusMap[status.ToLower()];
        return await _db.Orders
            .FromSqlRaw($"SELECT * FROM Orders WHERE Status = '{mapped}'")
            .ToListAsync(ct);
    }

    public decimal TotalFor(IEnumerable<Order> orders)
    {
        if (!orders.Any()) return 0m;
        return orders.Sum(o => o.Total) - orders.Sum(o => o.RefundedAmount);
    }
}
'@

Write-Fixture 'src/Shop.Api/Controllers/OrdersController.cs' @'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Shop.Api.Data;
using Shop.Api.Models;
using Shop.Api.Services;

namespace Shop.Api.Controllers;

[ApiController]
[Route("api/orders")]
[Authorize]
public class OrdersController : ControllerBase
{
    private readonly OrderRepository _orders;
    private readonly PaymentService _payments;

    public OrdersController(OrderRepository orders, PaymentService payments)
    {
        _orders = orders;
        _payments = payments;
    }

    [HttpPost("{id:int}/capture")]
    public async Task<IActionResult> Capture(int id, CancellationToken ct)
    {
        var order = await _orders.FindAsync(id, ct);
        if (order is null) return NotFound();
        var ok = await _payments.CaptureAsync(order, ct);
        return ok ? Ok(order) : Problem("Capture failed");
    }

    [HttpPost("{id:int}/refund")]
    public async Task<IActionResult> Refund(int id, [FromQuery] decimal amount, CancellationToken ct)
    {
        var order = await _orders.FindAsync(id, ct);
        if (order is null) return NotFound();
        var ok = await _payments.RefundAsync(order, amount);
        return ok ? Ok(order) : Problem("Refund failed");
    }
}
'@

Write-Fixture 'web/src/api/orders.ts' @'
export interface Order {
  id: number;
  customerEmail: string;
  total: number;
  status: string;
}

export async function captureOrder(id: number): Promise<Order> {
  const res = await fetch(`/api/orders/${id}/capture`, { method: "POST" });
  if (!res.ok) throw new Error(`Capture failed: ${res.status}`);
  return res.json();
}

export async function refundOrder(id: number, amount: number): Promise<Order> {
  const res = await fetch(`/api/orders/${id}/refund?amount=${amount}`, {
    method: "POST",
  });
  return res.json();
}

export function formatRefund(order: Order, refunded: number): string {
  const remaining = order.total - refunded;
  return `${(remaining * 100) / 100} remaining`;
}
'@

Write-Fixture 'web/src/pages/OrderPage.tsx' @'
import { Order, captureOrder, refundOrder } from "../api/orders";

export function OrderSummary({ order }: { order: Order }) {
  const canRefund = order.status === "captured";

  return (
    <div>
      <span>{order.customerEmail}</span>
      <span>{order.status}</span>
      <button onClick={() => captureOrder(order.id)}>Capture</button>
      {canRefund && (
        <button onClick={() => { refundOrder(order.id, order.total); }}>
          Refund
        </button>
      )}
    </div>
  );
}
'@

# Noise the skip patterns should keep away from the per-file reviewers.
Write-Fixture 'web/package-lock.json' '{ "name": "web", "lockfileVersion": 3, "packages": { "node_modules/left-pad": { "version": "1.3.0" } } }'
Write-Fixture 'src/Shop.Api/Migrations/20260101000000_Init.Designer.cs' @'
// <auto-generated />
namespace Shop.Api.Migrations;
public partial class Init { public const string Version = "2"; }
'@

Invoke-FixtureGit @('add', '-A')
Invoke-FixtureGit @('commit', '-q', '-m', 'Add refunds', '-m', 'Adds a refund endpoint, an OrderStatus enum and refund tracking on orders.')

Write-Output $Path
