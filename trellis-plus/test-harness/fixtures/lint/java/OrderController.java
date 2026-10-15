package com.acme;

public class OrderController {
    private final OrderService service;
    public OrderController(OrderService s) { this.service = s; }
    public Long post(OrderDTO dto) { return service.create(dto); }
}
