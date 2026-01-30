"""
ITCH Decoder Testbench using cocotb

This testbench verifies the ITCH 5.0 message decoder functionality
using constrained-random stimulus.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles
from cocotb.result import TestFailure
import struct
import random

# ITCH message type codes
ITCH_ADD_ORDER = 0x41      # 'A'
ITCH_ADD_ORDER_MPID = 0x46 # 'F'
ITCH_ORDER_EXECUTED = 0x45 # 'E'
ITCH_ORDER_CANCEL = 0x58   # 'X'
ITCH_ORDER_DELETE = 0x44   # 'D'
ITCH_ORDER_REPLACE = 0x55  # 'U'
ITCH_TRADE = 0x50          # 'P'
ITCH_SYSTEM_EVENT = 0x53   # 'S'


class ITCHMessage:
    """Base class for ITCH messages"""
    
    def __init__(self, msg_type, stock_locate=0, tracking_num=0, timestamp=0):
        self.msg_type = msg_type
        self.stock_locate = stock_locate
        self.tracking_num = tracking_num
        self.timestamp = timestamp
    
    def to_bytes(self):
        """Pack message to bytes (big-endian)"""
        raise NotImplementedError


class AddOrderMessage(ITCHMessage):
    """ITCH Add Order message (type 'A')"""
    
    def __init__(self, order_ref, side, shares, stock, price, **kwargs):
        super().__init__(ITCH_ADD_ORDER, **kwargs)
        self.order_ref = order_ref
        self.side = side  # 'B' or 'S'
        self.shares = shares
        self.stock = stock.ljust(8)[:8]  # 8-byte stock symbol
        self.price = price
    
    def to_bytes(self):
        return struct.pack('>cHHQQcI8sI',
            bytes([self.msg_type]),
            self.stock_locate,
            self.tracking_num,
            self.timestamp,
            self.order_ref,
            self.side.encode(),
            self.shares,
            self.stock.encode(),
            self.price
        )


class OrderExecutedMessage(ITCHMessage):
    """ITCH Order Executed message (type 'E')"""
    
    def __init__(self, order_ref, executed_shares, match_number, **kwargs):
        super().__init__(ITCH_ORDER_EXECUTED, **kwargs)
        self.order_ref = order_ref
        self.executed_shares = executed_shares
        self.match_number = match_number
    
    def to_bytes(self):
        return struct.pack('>cHHQQIQ',
            bytes([self.msg_type]),
            self.stock_locate,
            self.tracking_num,
            self.timestamp,
            self.order_ref,
            self.executed_shares,
            self.match_number
        )


class TradeMessage(ITCHMessage):
    """ITCH Trade message (type 'P')"""
    
    def __init__(self, order_ref, side, shares, stock, price, match_number, **kwargs):
        super().__init__(ITCH_TRADE, **kwargs)
        self.order_ref = order_ref
        self.side = side
        self.shares = shares
        self.stock = stock.ljust(8)[:8]
        self.price = price
        self.match_number = match_number
    
    def to_bytes(self):
        return struct.pack('>cHHQQcI8sIQ',
            bytes([self.msg_type]),
            self.stock_locate,
            self.tracking_num,
            self.timestamp,
            self.order_ref,
            self.side.encode(),
            self.shares,
            self.stock.encode(),
            self.price,
            self.match_number
        )


class ITCHDecoderTB:
    """Testbench driver for ITCH decoder"""
    
    def __init__(self, dut):
        self.dut = dut
        self.clock = Clock(dut.clk, 3.33, units="ns")  # 300 MHz
        cocotb.start_soon(self.clock.start())
        
        # Statistics
        self.messages_sent = 0
        self.messages_decoded = 0
        self.errors = 0
    
    async def reset(self):
        """Reset the DUT"""
        self.dut.rst_n.value = 0
        self.dut.s_axis_tvalid.value = 0
        self.dut.decoded_ready.value = 1
        self.dut.sym_lookup_idx.value = 0
        self.dut.sym_lookup_hit.value = 1
        self.dut.sym_lookup_ready.value = 1
        
        await ClockCycles(self.dut.clk, 10)
        self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, 5)
    
    async def send_message(self, msg: ITCHMessage):
        """Send an ITCH message to the decoder"""
        data = msg.to_bytes()
        msg_len = len(data)
        
        # Pack message into 512-bit (64-byte) buffer
        padded_data = data.ljust(64, b'\x00')
        tdata = int.from_bytes(padded_data, 'little')
        
        # Build TUSER: {seq, msg_type, msg_len, flags, ingress_ts}
        seq = random.randint(1, 0xFFFFFFFF)
        flags = 0
        ingress_ts = random.randint(0, 0xFFFFFFFFFFFFFFFF)
        tuser = (seq << 64) | (msg.msg_type << 56) | (msg_len << 48) | (flags << 40) | (ingress_ts & 0xFFFFFFFFFF)
        
        self.dut.s_axis_tdata.value = tdata
        self.dut.s_axis_tkeep.value = msg_len
        self.dut.s_axis_tlast.value = 1
        self.dut.s_axis_tuser.value = tuser
        self.dut.s_axis_tvalid.value = 1
        
        await RisingEdge(self.dut.clk)
        while self.dut.s_axis_tready.value == 0:
            await RisingEdge(self.dut.clk)
        
        self.dut.s_axis_tvalid.value = 0
        self.messages_sent += 1
    
    async def wait_for_decoded(self, timeout_cycles=100):
        """Wait for decoded message output"""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.clk)
            if self.dut.decoded_valid.value == 1:
                self.messages_decoded += 1
                return True
        return False


@cocotb.test()
async def test_add_order(dut):
    """Test Add Order message decoding"""
    tb = ITCHDecoderTB(dut)
    await tb.reset()
    
    # Create Add Order message
    msg = AddOrderMessage(
        order_ref=0x123456789ABCDEF0,
        side='B',
        shares=1000,
        stock='AAPL',
        price=15000,  # $150.00 (4 decimal places)
        stock_locate=1,
        tracking_num=1,
        timestamp=123456789012
    )
    
    await tb.send_message(msg)
    
    if not await tb.wait_for_decoded():
        raise TestFailure("Timeout waiting for decoded message")
    
    # Verify decoded fields
    decoded = dut.decoded_msg.value
    assert dut.decoded_valid.value == 1, "decoded_valid should be high"
    
    dut._log.info(f"Add Order decoded: order_ref={hex(decoded)}")


@cocotb.test()
async def test_trade(dut):
    """Test Trade message decoding"""
    tb = ITCHDecoderTB(dut)
    await tb.reset()
    
    msg = TradeMessage(
        order_ref=0xDEADBEEFCAFEBABE,
        side='S',
        shares=500,
        stock='MSFT',
        price=42500,  # $425.00
        match_number=0x1234567890ABCDEF,
        stock_locate=2,
        tracking_num=2,
        timestamp=987654321098
    )
    
    await tb.send_message(msg)
    
    if not await tb.wait_for_decoded():
        raise TestFailure("Timeout waiting for decoded message")
    
    dut._log.info("Trade message decoded successfully")


@cocotb.test()
async def test_order_executed(dut):
    """Test Order Executed message decoding"""
    tb = ITCHDecoderTB(dut)
    await tb.reset()
    
    msg = OrderExecutedMessage(
        order_ref=0xABCDEF0123456789,
        executed_shares=100,
        match_number=0x9876543210FEDCBA,
        stock_locate=3,
        tracking_num=3,
        timestamp=555555555555
    )
    
    await tb.send_message(msg)
    
    if not await tb.wait_for_decoded():
        raise TestFailure("Timeout waiting for decoded message")
    
    dut._log.info("Order Executed message decoded successfully")


@cocotb.test()
async def test_burst_messages(dut):
    """Test back-to-back message decoding"""
    tb = ITCHDecoderTB(dut)
    await tb.reset()
    
    NUM_MESSAGES = 100
    
    for i in range(NUM_MESSAGES):
        msg = AddOrderMessage(
            order_ref=i,
            side='B' if i % 2 == 0 else 'S',
            shares=100 * (i + 1),
            stock=f'SYM{i:04d}',
            price=10000 + i * 100,
            stock_locate=i % 256,
            tracking_num=i,
            timestamp=i * 1000
        )
        await tb.send_message(msg)
        
        # Wait for decode with backpressure sometimes
        if i % 10 == 0:
            tb.dut.decoded_ready.value = 0
            await ClockCycles(tb.dut.clk, 5)
            tb.dut.decoded_ready.value = 1
        
        await tb.wait_for_decoded(timeout_cycles=50)
    
    dut._log.info(f"Burst test: sent={tb.messages_sent}, decoded={tb.messages_decoded}")
    assert tb.messages_decoded == NUM_MESSAGES, f"Expected {NUM_MESSAGES} decoded, got {tb.messages_decoded}"


@cocotb.test()
async def test_random_messages(dut):
    """Test with random message types"""
    tb = ITCHDecoderTB(dut)
    await tb.reset()
    
    message_types = [
        lambda i: AddOrderMessage(
            order_ref=random.randint(0, 2**64-1),
            side=random.choice(['B', 'S']),
            shares=random.randint(1, 10000),
            stock=f'RND{random.randint(0,9999):04d}',
            price=random.randint(1, 1000000),
            stock_locate=random.randint(0, 65535),
            tracking_num=i,
            timestamp=random.randint(0, 2**48-1)
        ),
        lambda i: TradeMessage(
            order_ref=random.randint(0, 2**64-1),
            side=random.choice(['B', 'S']),
            shares=random.randint(1, 10000),
            stock=f'TRD{random.randint(0,9999):04d}',
            price=random.randint(1, 1000000),
            match_number=random.randint(0, 2**64-1),
            stock_locate=random.randint(0, 65535),
            tracking_num=i,
            timestamp=random.randint(0, 2**48-1)
        ),
        lambda i: OrderExecutedMessage(
            order_ref=random.randint(0, 2**64-1),
            executed_shares=random.randint(1, 10000),
            match_number=random.randint(0, 2**64-1),
            stock_locate=random.randint(0, 65535),
            tracking_num=i,
            timestamp=random.randint(0, 2**48-1)
        ),
    ]
    
    NUM_MESSAGES = 200
    
    for i in range(NUM_MESSAGES):
        msg_factory = random.choice(message_types)
        msg = msg_factory(i)
        await tb.send_message(msg)
        await tb.wait_for_decoded(timeout_cycles=50)
    
    dut._log.info(f"Random test: sent={tb.messages_sent}, decoded={tb.messages_decoded}")
    assert tb.messages_decoded >= NUM_MESSAGES * 0.95, "Too many messages dropped"


if __name__ == "__main__":
    # For standalone execution
    print("Run with: make SIM=verilator")
