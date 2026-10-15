package com.acme;

public class OrderService {
    private final OrderMapper mapper;
    public OrderService(OrderMapper mapper) { this.mapper = mapper; }

    public Long create(OrderDTO dto) {
        if (dto == null) throw new IllegalArgumentException("dto");
        return mapper.insert(dto);
    }
}
