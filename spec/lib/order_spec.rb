# coding: utf-8
require 'spec_helper'

RSpec.describe StraightServer::Order do

  before(:each) do
    # clean the database
    StraightServer.db_connection.run("DELETE FROM orders")
    @gateway = double("Straight Gateway mock")
    allow(@gateway).to receive(:id).and_return(1)
    allow(@gateway).to receive(:active).and_return(true)
    allow(@gateway).to receive(:order_status_changed)
    allow(@gateway).to receive(:test_mode).and_return(false)
    allow(@gateway).to receive(:save)
    allow(@gateway).to receive(:increment_order_counter!)
    allow(@gateway).to receive(:current_exchange_rate).and_return(111)
    allow(@gateway).to receive(:default_currency).and_return('USD')
    allow(@gateway).to receive(:last_keychain_id).and_return(222)
    @order = create(:order, gateway_id: @gateway.id)
    allow(@gateway).to receive(:fetch_transactions_for).with(anything).and_return([])
    allow(@gateway).to receive(:order_status_changed).with(anything)
    allow(@gateway).to receive(:sign_with_secret).with(anything).and_return("1", "2", "3")
    allow(StraightServer::Gateway).to receive(:find_by_id).and_return(@gateway)

    websockets = {}
    StraightServer::GatewayOnConfig.class_variable_get(:@@gateways).each do |g|
      websockets[g.id] = {}
    end
    StraightServer::GatewayModule.class_variable_set(:@@websockets, websockets)
  end

  it "prepares data as http params" do
    allow(@order).to receive(:tid).and_return("tid1")
    expect(@order.to_http_params).to eq(
      "order_id=#{@order.id}&amount=10&amount_in_btc=#{@order.amount_in_btc(as: :string)}&" \
      "amount_paid_in_btc=#{@order.amount_in_btc(field: @order.amount_paid, as: :string)}&" \
      "status=#{@order.status}&address=#{@order.address}&tid=tid1&transaction_ids=[]&keychain_id=#{@order.keychain_id}&" \
      "last_keychain_id=#{@order.gateway.last_keychain_id}&after_payment_redirect_to=#{@order.after_payment_redirect_to}&" \
      "auto_redirect=#{@order.auto_redirect}"
    )
  end

  it "generates a payment_id" do
    expect(@order.payment_id).not_to be_nil
  end

  it "starts a periodic status check but subtracts the time passed from order creation from the duration of the check" do
    expect(@order).to receive(:check_status_on_schedule).with(duration: 900)
    @order.start_periodic_status_check

    @order.created_at = (Time.now - 100)
    expect(@order).to receive(:check_status_on_schedule).with(duration: 800)
    @order.start_periodic_status_check
  end

  it "checks DB for a status update first if the respective option for the gateway is turned on" do
    # allow(@order).to receive(:transaction).and_raise("Shouldn't ever be happening!")
    StraightServer::Config.check_order_status_in_db_first = true
    StraightServer::Order.where(id: @order.id).update(status: 2)
    allow(@order.gateway).to receive(:fetch_transactions_for).and_return([])
    allow(@order.gateway).to receive(:order_status_changed)
    expect(@order.status(reload: false)).to eq(0)
    expect(@order.status(reload: true)).to eq(2)
  end

  it "updates order status when the time in which it expires passes (periodic status checks finish)" do
    allow(@order).to receive(:status=) do
      expect(@order).to receive(:status_changed?).and_return(true)
      expect(@order).to receive(:save)
    end
    allow(@order).to receive(:check_status_on_schedule).with(duration: 900) { @order.status = 5 }
    @order.start_periodic_status_check
  end

  it "doesn't allow to create an order for inactive gateway" do
    allow(@gateway).to receive(:active).and_return(false)
    expect( -> { create(:order, gateway_id: @gateway.id) }).to raise_exception(Sequel::ValidationFailed, "gateway is inactive, cannot create order for inactive gateway")
  end

  it "adds exchange rate at the moment of purchase to the data hash" do
    order = create(:order, gateway_id: @gateway.id)
    expect(order.data[:exchange_rate]).to eq({ price: 111, currency: 'USD' })
  end

  it "returns last_keychain_id for the gateway along with other order data" do
    order = create(:order, gateway_id: @gateway.id)
    expect(order.to_h).to include(keychain_id: order.keychain_id, last_keychain_id: @gateway.last_keychain_id)
  end

  it "returns test_last_keychain_id (as last_keychain_id) for the gateway in test mode" do
    allow(@gateway).to receive(:test_mode).and_return(true)
    allow(@gateway).to receive(:test_last_keychain_id).and_return(123)
    order = create(:order, gateway_id: @gateway.id)
    expect(order.to_h[:last_keychain_id]).to eq(123)
  end

  it 'is cancelable only while new' do
    order = build(:order, gateway_id: @gateway.id, status: 0)
    expect(order.cancelable?).to eq true
    (1..6).each do |status|
      order.instance_variable_set :@status, status
      expect(order.cancelable?).to eq false
    end
  end

  it "calculates amount to pay" do
    @order.amount      = 10000
    @order.amount_paid = 0
    expect(@order.amount_to_pay_in_btc).to eq '0.0001'

    @order.amount_paid = 3001
    expect(@order.amount_to_pay_in_btc).to eq '0.00006999'

    @order.amount_paid = 9999
    expect(@order.amount_to_pay_in_btc).to eq '0.00000547'
  end

  describe "DB interaction" do

    it "saves a new order into the database" do
      expect(StraightServer.db_connection[:orders][:keychain_id => @order.id]).not_to be_nil
    end

    it "updates an existing order" do
      allow(@order).to receive(:gateway).and_return(@gateway)
      expect(StraightServer.db_connection[:orders][:keychain_id => @order.id][:status]).to eq(0)
      @order.status = 1
      expect(StraightServer.db_connection[:orders][:keychain_id => @order.id][:status]).to eq(1)
    end

    it "finds first order in the database by id" do
      expect(StraightServer::Order.find(id: @order.id)).to equal_order(@order)
    end

    it "finds first order in the database by keychain_id" do
      expect(StraightServer::Order.find(keychain_id: @order.keychain_id)).to equal_order(@order)
    end

    it "finds orders in the database by any conditions" do
      order1 = create(:order, gateway_id: @gateway.id)
      order2 = create(:order, gateway_id: @gateway.id)

      expect(StraightServer::Order.where(keychain_id: order1.keychain_id).first).to equal_order(order1)
      expect(StraightServer::Order.where(keychain_id: order2.keychain_id).first).to equal_order(order2)
      expect(StraightServer::Order.where(keychain_id: order2.keychain_id+1).first).to be_nil

    end

    describe "with validations" do

      it "doesn't save order if the order with the same id exists" do
        order = create(:order, gateway_id: @gateway.id)
        expect( -> { create(:order, id: order.id, gateway_id: @gateway.id) }).to raise_error(Sequel::ValidationFailed)
      end

      it "doesn't save order if the amount is invalid" do
        expect( -> { create(:order, amount: 0) }).to raise_error(Sequel::ValidationFailed)
      end

      it "doesn't save order if gateway_id is invalid" do
        expect( -> { create(:order, gateway_id: 0) }).to raise_error(Sequel::ValidationFailed)
      end

      it "doesn't save order if description is too long" do
        expect( -> { create(:order, description: ("text" * 100)) }).to raise_error(Sequel::ValidationFailed)
      end

    end

    describe "accepted transactions" do

      it "persists accepted transactions" do
        transactions = [{tid: '1', amount: 1, confirmations: 1, block_height: 100000}, {tid: '2', amount: 2}, {tid: '3', amount: 3}]

        expect(@order.accepted_transactions.size).to eq 0
        expect {
          @order.accepted_transactions = transactions[0, 1]
        }.to change { StraightServer::Transaction.count }.by(1)
        expect(@order.accepted_transactions.size).to eq 1

        @order.on_accepted_transactions_updated = lambda { }
        expect(@order.on_accepted_transactions_updated).to receive(:call).exactly(2).times.and_raise('meah')

        expect {
          @order.accepted_transactions = Straight::Transaction.from_hashes(transactions[1, 1])
        }.to change { StraightServer::Transaction.count }.by(1)
        expect(@order.accepted_transactions.size).to eq 2

        expect {
          @order.accepted_transactions = [StraightServer::Transaction.new(transactions[2])]
        }.to change { StraightServer::Transaction.count }.by(1)
        expect(@order.accepted_transactions.size).to eq 3

        expect {
          @order.accepted_transactions = transactions
        }.to change { StraightServer::Transaction.count }.by(0)

        (0..2).each do |i|
          expect(@order.accepted_transactions[i].to_hash).to include transactions[i]
          expect(@order.accepted_transactions(as: :straight)[i].to_h).to include transactions[i]
        end

        expect(@order.accepted_transactions.map(&:class).uniq).to eq [StraightServer::Transaction]
        expect(@order.accepted_transactions(as: :straight).map(&:class).uniq).to eq [Straight::Transaction]
      end
    end

  end

end
