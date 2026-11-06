select count(*) as orders, sum(amount) as total_amount
from   orders
where  trunc(order_date) = date '2025-03-15'
and    status = 'SHIPPED';
