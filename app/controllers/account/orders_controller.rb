class Account::OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :check_order_info, only: :create
  before_action :find_order_by_number, only: [:show, :pay, :cancel, :make_payment, :apply_for_cancel, :confirm_receipt, :apply_for_return]
  before_action :save_back_url, only: [:create, :pay, :cancel, :make_payment, :apply_for_cancel, :confirm_receipt, :apply_for_return]

  def index
    if params[:start_date].present?
      start_date = Date.strptime(params[:start_date], "%m/%d/%Y")
      end_date = params[:end_date].present? ? Date.strptime(params[:end_date], "%m/%d/%Y") : Date.today
      @orders = current_user.orders.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
    else
      @orders = current_user.orders.recent
    end
    @orders = @orders.page(params[:page]).per_page(10)
  end

  def show
    @order_details = @order.order_details
  end

  def create
    # 检查库存
    if check_stock
      # 生成订单
      if create_order
        # 前往支付页
        redirect_to pay_account_order_path(@order.number)
      end
    end
  end

  # 支付页
  def pay
  end

  # 取消订单
  def cancel
    if @order.placed?
      @order.cancel!
      operation_error(:notice, "订单#{@order.number}已取消")
    elsif @order.cancelled?
      # 订单已经取消
      operation_error(:warning, "订单#{@order.number}已经取消，不能重复取消！")
    elsif @order.shipping? || @order.shipped?
      # 订单已经出货
      operation_error(:warning, "您的订单#{@order.number}已经出货，请您申请退货！")
    elsif @order.applying_for_return?
      # 申请退货中
      operation_error(:warning, "您的订单#{@order.number}正在申请退货，不能取消！")
    else
      # 其他情况
      operation_error(:alert, "您的订单#{@order.number}取消失败！")
    end
  end

  # 完成支付
  def make_payment
    # 订单已经支付
    if @order.placed?
      @order.make_payment!
      flash[:notice] = "订单支付成功！"
      redirect_to account_orders_path
      # 发送完成支付通知
      OrderMailer.notify_order_paid(@order).deliver!
    else
      operation_error(:warning, "订单#{@order.number}已经完成支付，不能重复支付！")
    end
  end

  # 申请取消订单
  def apply_for_cancel
    if @order.paid?
      @order.apply_for_cancel!
      operation_error(:notice, "订单#{@order.number}已提交取消申请，请耐心等待审核")
      # 发送申请取消订单通知
      OrderMailer.notify_apply_cancel(@order).deliver!
    elsif @order.cancelled?
      # 订单已经取消
      operation_error(:warning, "订单#{@order.number}已经取消，不能重复取消！")
    elsif @order.shipping? || @order.shipped?
      # 订单已经出货
      operation_error(:warning, "您的订单#{@order.number}已经出货，请您申请退货！")
    elsif @order.applying_for_return?
      # 申请退货中
      operation_error(:warning, "您的订单#{@order.number}正在申请退货，不能取消！")
    else
      # 其他情况
      operation_error(:alert, "您的订单#{@order.number}取消失败！")
    end
  end

  # 确认收货
  def confirm_receipt
    if @order.shipping?
      # 订单正在配送
      @order.confirm_receipt!
      operation_error(:notice, "您的订单#{@order.number}成功确认收货！")
      # 发送确认收货通知
      OrderMailer.notify_order_receipt(@order).deliver!
      # 发送订单完成通知
      OrderMailer.notify_order_finished(@order).deliver!
    elsif @order.cancelled?
      # 订单已经取消
      operation_error(:warning, "您的订单#{@order.number}已经取消！")
    elsif @order.shipped?
      # 订单已经确认收货
      operation_error(:warning, "您的订单#{@order.number}已经确认收货，不能重复确认收货！")
    elsif @order.returned?
      operation_error(:warning, "您的订单#{@order.number}已经退货！")
    else
      # 其他情况
      operation_error(:alert, "您的订单#{@order.number}确认收货失败！")
    end
  end

  # 申请退货
  def apply_for_return
    if @order.shipping? || @order.shipped?
      # 订单正在配送或送达
      @order.apply_for_return!
      operation_error(:notice, "订单#{@order.number}的退货申请已经提交！")
      # 发送申请退货通知
      OrderMailer.notify_apply_return(@order).deliver!
    elsif @order.cancelled?
      # 订单已经取消
      operation_error(:warning, "您的订单#{@order.number}已经取消！")
    elsif @order.returned?
      operation_error(:warning, "您的订单#{@order.number}已经退货！")
    else
      # 其他情况
      operation_error(:alert, "您的订单#{@order.number}申请退货失败！")
    end
  end

  private

  # 检查订单信息
  def check_order_info
    # 获取收获地址
    if params[:selected_address] == "none"
      return checkout_error(:warning, "请选择一个收货地址！")
    end
    @address = Address.find(params[:selected_address])
    # 获取支付方式
    if params[:payment_method] == "none"
      return checkout_error(:warning, "请选择一个支付方式！")
    end
    @payment = params[:payment_method]
  end

  # 检查库存
  def check_stock
    # 获取购物清单
    @items = CartItem.where(id: params[:items])
    @items.each do |item|
      @product = item.product
      # 已售罄
      if @product.is_sold_out?
        return order_error(:warning, "课程#{@product.title}名额已满！")
      # 订单名额超过剩余名额
      elsif item.quantity > @product.quantity
        return order_error(:warning, "您报名课程#{@product.title}的名额超出剩余名额！")
      # 成功变更库存
      elsif @product.change_stock!(-item.quantity)
        return true
      else
        return order_error(:alert, "非常抱歉，您报名课程#{@product.title}的请求出错了！")
      end
    end
  end

  # 生成订单
  def create_order
    @order = current_user.orders.build
    @order.name = @address.name
    @order.cellphone = @address.cellphone
    @order.address = @address.address
    @order.payment_method = @payment
    @order.total_price = current_cart.total_price(@items)
    if @order.save
      return create_order_details
    else
      return order_error(:alert, "生成订单出错！")
    end
    # 发送下单通知
    OrderMailer.notify_order_placed(@order).deliver!
    return true
  end

  # 生成购物清单
  def create_order_details
    @order_details = []
    @items.each do |item|
      # 生成订单详情
      @order_detail = @order.order_details.build
      @order_detail.product = item.product
      @order_detail.image = item.product.image
      @order_detail.title = item.product.title
      @order_detail.description = item.product.description
      @order_detail.price = item.product.price
      @order_detail.quantity = item.quantity
      unless @order_detail.save
        return order_error(:alert, "生成购物清单出错！")
      end
    end
    # 删除完成结算的课程
    @items.destroy_all
    return true
  end

  # 处理订单生成异常
  def checkout_error(level, msg)
    flash[level] = msg
    redirect_to checkout_cart_path(current_cart, item_ids: params[:items])
  end

  # 处理订单生成异常
  def order_error(level, msg)
    if @order.present?
      @order.destroy
    end
    flash[level] = msg
    redirect_to carts_path
    return false
  end

  # 处理用户操作异常
  def operation_error(level, msg)
    flash[level] = msg
    back account_orders_path
  end

  def find_order_by_number
    @order = Order.find_by_number(params[:id])
  end
end
