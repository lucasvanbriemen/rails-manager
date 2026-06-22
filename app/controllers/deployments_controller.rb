class DeploymentsController < ApplicationController
  def show
    @app = App.find(params[:app_id])
    @deployment = @app.deployments.find(params[:id])

    respond_to do |format|
      format.html
      format.json do
        render json: {
          status: @deployment.status,
          finished: @deployment.finished?,
          log: @deployment.log
        }
      end
    end
  end
end
