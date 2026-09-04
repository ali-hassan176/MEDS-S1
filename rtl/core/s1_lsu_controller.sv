// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// s1_lsu_controller : scalar LSU request/response controller       [WIP -- R-02]
//
// Accepts one decoded scalar memory operation, checks its basic legality,
// performs one MEM-REQ transaction, and holds the result until the core accepts
// it. PMA and PMP are explicit decision ports; they are supplied externally so
// their later implementations do not change this controller's datapath.
// Reference: MEDS-S1 specification sections 11, 14 and INTERFACES.md section 2.

module s1_lsu_controller
  import s1_pkg::*;
#(
  parameter int unsigned WIDTH = 64
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             lsu_valid_i,
  output logic             lsu_ready_o,
  input logic [WIDTH-1:0] lsu_addr_i,
  input logic [WIDTH-1:0] lsu_wdata_i,
  input logic [2:0]       lsu_size_i,
  input  logic             lsu_write_i,
  input  logic             lsu_unsigned_i,
  input  priv_lvl_e        lsu_mode_i,
  input  logic [3:0]       lsu_id_i,

  output logic             check_valid_o,
  output logic [WIDTH-1:0] check_addr_o,
  output logic [2:0]       check_size_o,
  output logic             check_write_o,
  output priv_lvl_e        check_mode_o,
  input  logic             pmp_allow_i,
  input  logic             pma_allow_i,
  input  logic [5:0]       pmp_fault_code_i,
  input  logic [5:0]       pma_fault_code_i,

  output logic             mem_req_valid_o,
  input  logic             mem_req_ready_i,
  output mem_req_t         mem_req_o,

  input  logic             mem_rsp_valid_i,
  output logic             mem_rsp_ready_o,
  input  mem_rsp_t         mem_rsp_i,

  output logic             lsu_resp_valid_o,
  input  logic             lsu_resp_ready_i,
  output logic [WIDTH-1:0]  lsu_rdata_o,
  output logic             lsu_fault_o,
  output logic [5:0]       lsu_fault_code_o,
  output logic [WIDTH-1:0]  lsu_fault_addr_o
);

  localparam logic [5:0] LOAD_MISALIGNED  = 6'd4;
  localparam logic [5:0] LOAD_ACCESS_FAULT = 6'd5;
  localparam logic [5:0] STORE_MISALIGNED = 6'd6;
  localparam logic [5:0] STORE_ACCESS_FAULT = 6'd7;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_CHECK,
    ST_ISSUE,
    ST_WAIT_RSP,
    ST_RESP
  } state_e;

  state_e state_q, state_d;

  logic [WIDTH-1:0] addr_q, wdata_q;
  logic [2:0]      size_q;
  logic            write_q, unsigned_q;
  priv_lvl_e       mode_q;
  logic [3:0]      id_q;

  logic [WIDTH-1:0] response_data_q;
  logic            response_fault_q;
  logic [5:0]      response_fault_code_q;
  logic [WIDTH-1:0] response_fault_addr_q;

  logic             size_valid;
  logic             alignment_ok;
  logic [WIDTH/8-1:0] mem_be;
  logic [WIDTH-1:0]   mem_wdata;
  logic [WIDTH-1:0]   load_data;

  s1_lsu_datapath #(.XLEN(WIDTH)) datapath (
    .addr_i            (addr_q),
    .store_data_i      (wdata_q),
    .size_i            (size_q),
    .load_unsigned_i   (unsigned_q),
    .response_data_i   (mem_rsp_i.rdata),
    .size_valid_o      (size_valid),
    .alignment_ok_o    (alignment_ok),
    .mem_be_o          (mem_be),
    .mem_wdata_o       (mem_wdata),
    .load_data_o       (load_data)
  );

  always_comb begin
    state_d = state_q;
    case (state_q)
      ST_IDLE: begin
        if (lsu_valid_i) state_d = ST_CHECK;
      end
      ST_CHECK: begin
        if (!size_valid || !alignment_ok || !pmp_allow_i || !pma_allow_i) begin
          state_d = ST_RESP;
        end else begin
          state_d = ST_ISSUE;
        end
      end
      ST_ISSUE: begin
        if (mem_req_ready_i) state_d = ST_WAIT_RSP;
      end
      ST_WAIT_RSP: begin
        if (mem_rsp_valid_i && mem_rsp_i.id == id_q) state_d = ST_RESP;
      end
      ST_RESP: begin
        if (lsu_resp_ready_i) state_d = ST_IDLE;
      end
      default: state_d = ST_IDLE;
    endcase
  end

  always_comb begin
    lsu_ready_o = (state_q == ST_IDLE);

    check_valid_o = (state_q == ST_CHECK);
    check_addr_o = addr_q;
    check_size_o = size_q;
    check_write_o = write_q;
    check_mode_o = mode_q;

    mem_req_valid_o = (state_q == ST_ISSUE);
    mem_req_o = '0;
    mem_req_o.addr = addr_q;
    mem_req_o.we = write_q;
    mem_req_o.be = mem_be;
    mem_req_o.wdata = mem_wdata;
    mem_req_o.size = size_q;
    mem_req_o.mode = mode_q;
    mem_req_o.id = id_q;

    mem_rsp_ready_o = (state_q == ST_WAIT_RSP);

    lsu_resp_valid_o = (state_q == ST_RESP);
    lsu_rdata_o = response_data_q;
    lsu_fault_o = response_fault_q;
    lsu_fault_code_o = response_fault_code_q;
    lsu_fault_addr_o = response_fault_addr_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      addr_q <= '0;
      wdata_q <= '0;
      size_q <= '0;
      write_q <= 1'b0;
      unsigned_q <= 1'b0;
      mode_q <= PRIV_M;
      id_q <= '0;
      response_data_q <= '0;
      response_fault_q <= 1'b0;
      response_fault_code_q <= '0;
      response_fault_addr_q <= '0;
    end else begin
      state_q <= state_d;

      if (state_q == ST_IDLE && lsu_valid_i) begin
        addr_q <= lsu_addr_i;
        wdata_q <= lsu_wdata_i;
        size_q <= lsu_size_i;
        write_q <= lsu_write_i;
        unsigned_q <= lsu_unsigned_i;
        mode_q <= lsu_mode_i;
        id_q <= lsu_id_i;
      end

      if (state_q == ST_CHECK && state_d == ST_RESP) begin
        response_data_q <= '0;
        response_fault_q <= 1'b1;
        response_fault_addr_q <= addr_q;
        if (!size_valid || !alignment_ok) begin
          response_fault_code_q <= write_q ? STORE_MISALIGNED : LOAD_MISALIGNED;
        end else if (!pmp_allow_i) begin
          response_fault_code_q <= (pmp_fault_code_i != 0) ?
                                   pmp_fault_code_i :
                                   (write_q ? STORE_ACCESS_FAULT : LOAD_ACCESS_FAULT);
        end else begin
          response_fault_code_q <= (pma_fault_code_i != 0) ?
                                   pma_fault_code_i :
                                   (write_q ? STORE_ACCESS_FAULT : LOAD_ACCESS_FAULT);
        end
      end

      if (state_q == ST_WAIT_RSP && mem_rsp_valid_i && mem_rsp_i.id == id_q) begin
        response_data_q <= write_q ? '0 : load_data;
        response_fault_q <= mem_rsp_i.err;
        response_fault_code_q <= mem_rsp_i.err ?
                                 (mem_rsp_i.errcode != 0 ? {4'b0, mem_rsp_i.errcode} :
                                  (write_q ? STORE_ACCESS_FAULT : LOAD_ACCESS_FAULT)) : '0;
        response_fault_addr_q <= addr_q;
      end

      if (state_q == ST_RESP && lsu_resp_ready_i) begin
        response_fault_q <= 1'b0;
        response_fault_code_q <= '0;
      end
    end
  end

endmodule
