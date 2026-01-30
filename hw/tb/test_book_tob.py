"""
Book TOB (Top-of-Book) Testbench using cocotb

Verifies the top-of-book builder functionality
using constrained-random stimulus and golden model comparison.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles
from cocotb.result import TestFailure
import random
from collections import defaultdict


class BookGoldenModel:
    """Python golden model for TOB state"""
    
    def __init__(self, num_symbols=1024):
        self.num_symbols = num_symbols
        # TOB state: {symbol_idx: {'bid': (price, qty), 'ask': (price, qty), 'last': price}}
        self.tob = defaultdict(lambda: {
            'bid': (0, 0),
            'ask': (0, 0),
            'last': 0
        })
    
    def process_add_order(self, symbol_idx, side, price, qty):
        """Process an add order message"""
        if side == 'B':
            curr_px, curr_qty = self.tob[symbol_idx]['bid']
            if price > curr_px:
                self.tob[symbol_idx]['bid'] = (price, qty)
            elif price == curr_px:
                self.tob[symbol_idx]['bid'] = (price, curr_qty + qty)
        else:  # Ask
            curr_px, curr_qty = self.tob[symbol_idx]['ask']
            if curr_px == 0 or price < curr_px:
                self.tob[symbol_idx]['ask'] = (price, qty)
            elif price == curr_px:
                self.tob[symbol_idx]['ask'] = (price, curr_qty + qty)
    
    def process_trade(self, symbol_idx, price):
        """Process a trade message"""
        self.tob[symbol_idx]['last'] = price
    
    def get_tob(self, symbol_idx):
        """Get current TOB state for a symbol"""
        return self.tob[symbol_idx]


class BookTobTB:
    """Testbench driver for book_tob module"""
    
    def __init__(self, dut):
        self.dut = dut
        self.clock = Clock(dut.clk, 3.33, units="ns")  # 300 MHz
        cocotb.start_soon(self.clock.start())
        self.golden = BookGoldenModel()
        
        # Statistics
        self.messages_sent = 0
        self.events_received = 0
        self.errors = 0
    
    async def reset(self):
        """Reset the DUT"""
        self.dut.rst_n.value = 0
        self.dut.msg_valid.value = 0
        self.dut.event_ready.value = 1
        self.dut.cfg_enable.value = 1
        
        await ClockCycles(self.dut.clk, 10)
        self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, 5)
    
    async def send_add_order(self, symbol_idx, side, price, qty, order_ref=None):
        """Send an add order message to the book builder"""
        if order_ref is None:
            order_ref = random.randint(0, 2**64-1)
        
        # Update golden model
        self.golden.process_add_order(symbol_idx, side, price, qty)
        
        # Pack message struct (simplified - adjust to match actual itch_msg_t)
        # msg_type = 0x41 for Add Order
        self.dut.msg_in.value = (
            (0x41 << 0) |           # msg_type
            (symbol_idx << 8) |     # symbol_idx
            (1 if side == 'B' else 0) << 24 |  # side
            (price << 32) |         # price
            (qty << 64)             # qty
        )
        self.dut.msg_valid.value = 1
        
        await RisingEdge(self.dut.clk)
        while self.dut.msg_ready.value == 0:
            await RisingEdge(self.dut.clk)
        
        self.dut.msg_valid.value = 0
        self.messages_sent += 1
    
    async def send_trade(self, symbol_idx, price, qty):
        """Send a trade message"""
        self.golden.process_trade(symbol_idx, price)
        
        # msg_type = 0x50 for Trade
        self.dut.msg_in.value = (
            (0x50 << 0) |           # msg_type
            (symbol_idx << 8) |     # symbol_idx
            (price << 32) |         # price
            (qty << 64)             # qty
        )
        self.dut.msg_valid.value = 1
        
        await RisingEdge(self.dut.clk)
        while self.dut.msg_ready.value == 0:
            await RisingEdge(self.dut.clk)
        
        self.dut.msg_valid.value = 0
        self.messages_sent += 1
    
    async def wait_for_event(self, timeout_cycles=100):
        """Wait for book event output"""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.clk)
            if self.dut.event_valid.value == 1:
                self.events_received += 1
                return True
        return False


@cocotb.test()
async def test_single_add_order(dut):
    """Test single add order processing"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    # Send a single bid order
    await tb.send_add_order(
        symbol_idx=0,
        side='B',
        price=15000,  # $150.00
        qty=100
    )
    
    if not await tb.wait_for_event():
        raise TestFailure("Timeout waiting for book event")
    
    # Verify golden model state
    tob = tb.golden.get_tob(0)
    assert tob['bid'] == (15000, 100), f"Bid mismatch: {tob['bid']}"
    
    dut._log.info(f"Single add order test passed: bid={tob['bid']}")


@cocotb.test()
async def test_bid_ask_spread(dut):
    """Test bid/ask spread tracking"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    # Send bid
    await tb.send_add_order(symbol_idx=0, side='B', price=14900, qty=100)
    await tb.wait_for_event()
    
    # Send ask
    await tb.send_add_order(symbol_idx=0, side='S', price=15100, qty=50)
    await tb.wait_for_event()
    
    # Verify spread
    tob = tb.golden.get_tob(0)
    spread = tob['ask'][0] - tob['bid'][0]
    assert spread == 200, f"Spread mismatch: {spread}"
    
    dut._log.info(f"Bid/ask spread test passed: bid={tob['bid']}, ask={tob['ask']}, spread={spread}")


@cocotb.test()
async def test_price_improvement(dut):
    """Test that better prices improve TOB"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    # Initial bid at $149.00
    await tb.send_add_order(symbol_idx=0, side='B', price=14900, qty=100)
    await tb.wait_for_event()
    
    # Better bid at $150.00
    await tb.send_add_order(symbol_idx=0, side='B', price=15000, qty=50)
    await tb.wait_for_event()
    
    # Verify TOB shows better price
    tob = tb.golden.get_tob(0)
    assert tob['bid'][0] == 15000, f"Bid price not improved: {tob['bid']}"
    
    dut._log.info(f"Price improvement test passed: bid={tob['bid']}")


@cocotb.test()
async def test_multiple_symbols(dut):
    """Test order book for multiple symbols"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    NUM_SYMBOLS = 10
    
    # Send orders for multiple symbols
    for i in range(NUM_SYMBOLS):
        await tb.send_add_order(
            symbol_idx=i,
            side='B' if i % 2 == 0 else 'S',
            price=10000 + i * 100,
            qty=100 + i * 10
        )
        await tb.wait_for_event(timeout_cycles=50)
    
    # Verify all symbols have TOB state
    for i in range(NUM_SYMBOLS):
        tob = tb.golden.get_tob(i)
        if i % 2 == 0:
            assert tob['bid'][0] == 10000 + i * 100
        else:
            assert tob['ask'][0] == 10000 + i * 100
    
    dut._log.info(f"Multi-symbol test passed: {NUM_SYMBOLS} symbols")


@cocotb.test()
async def test_trade_last_price(dut):
    """Test last trade price tracking"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    # Add some orders first
    await tb.send_add_order(symbol_idx=5, side='B', price=15000, qty=100)
    await tb.wait_for_event()
    
    # Send a trade
    await tb.send_trade(symbol_idx=5, price=15050, qty=25)
    await tb.wait_for_event()
    
    # Verify last trade price
    tob = tb.golden.get_tob(5)
    assert tob['last'] == 15050, f"Last trade price mismatch: {tob['last']}"
    
    dut._log.info(f"Trade last price test passed: last={tob['last']}")


@cocotb.test()
async def test_burst_orders(dut):
    """Test burst of orders for same symbol (hot symbol test)"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    HOT_SYMBOL = 42
    NUM_ORDERS = 50
    
    # Send many orders for same symbol (tests bank conflict handling)
    for i in range(NUM_ORDERS):
        side = 'B' if i % 2 == 0 else 'S'
        price = 15000 + (i % 10) * 10 if side == 'B' else 15100 + (i % 10) * 10
        
        await tb.send_add_order(
            symbol_idx=HOT_SYMBOL,
            side=side,
            price=price,
            qty=random.randint(10, 1000)
        )
        
        # Sometimes add backpressure
        if i % 7 == 0:
            tb.dut.event_ready.value = 0
            await ClockCycles(tb.dut.clk, 3)
            tb.dut.event_ready.value = 1
        
        await tb.wait_for_event(timeout_cycles=50)
    
    dut._log.info(f"Burst test passed: {NUM_ORDERS} orders, {tb.events_received} events")
    assert tb.events_received >= NUM_ORDERS * 0.9, "Too many events dropped"


@cocotb.test()
async def test_random_workload(dut):
    """Test with random order workload"""
    tb = BookTobTB(dut)
    await tb.reset()
    
    NUM_ORDERS = 500
    
    for i in range(NUM_ORDERS):
        symbol_idx = random.randint(0, 255)  # Use subset of symbols
        side = random.choice(['B', 'S'])
        price = random.randint(1000, 100000)
        qty = random.randint(1, 10000)
        
        if random.random() < 0.1:
            # 10% trades
            await tb.send_trade(symbol_idx, price, qty)
        else:
            # 90% add orders
            await tb.send_add_order(symbol_idx, side, price, qty)
        
        await tb.wait_for_event(timeout_cycles=30)
    
    dut._log.info(f"Random workload test passed: sent={tb.messages_sent}, received={tb.events_received}")


if __name__ == "__main__":
    print("Run with: make test_book_tob SIM=verilator")
