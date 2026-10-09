module QueryPersistenceConcern
  extend ActiveSupport::Concern

  QUERY_PERSISTENCE_TTL = 30.days

  module ClassMethods
    def persist_query_for(*actions)
      before_action :restore_query_from_cache, only: actions
      after_action :persist_query_to_cache, only: actions
    end
  end

  private

  def query_persistence_cache_key
    user_id = current_user&.id || "anon"
    "query_persistence:#{user_id}:#{controller_path}:#{action_name}"
  end

  def explicit_reset_requested?
    params[:reset].present?
  end

  def query_params_present?
    params[:q].present?
  end

  def restore_query_from_cache
    return unless query_persistence_enabled?
    return if query_params_present?

    if explicit_reset_requested?
      Rails.cache.delete(query_persistence_cache_key)
      return
    end

    saved = Rails.cache.read(query_persistence_cache_key)
    return if saved.blank?

    # Redirect so the browser URL reflects the restored filter state.
    # Only redirect for HTML requests — turbo_stream/JSON callers get params
    # mutated in-place to avoid a second round-trip.
    if request.format.html?
      redirect_to url_for(params.permit!.to_h.merge(q: saved))
    else
      params[:q] = ActionController::Parameters.new(saved)
    end
  rescue StandardError => e
    Rails.logger.warn { "QueryPersistence: Cache read failed: #{e.message}" }
    Rails.cache.delete(query_persistence_cache_key)
  end

  def persist_query_to_cache
    return unless query_persistence_enabled?
    return unless response.successful?

    query_hash = params[:q]&.permit!&.to_h
    return if query_hash.blank?

    # Exclude blank values to keep persisted filters clean
    query_hash = query_hash.reject { |_, v| v.blank? }
    return if query_hash.blank?

    Rails.cache.write(
      query_persistence_cache_key,
      query_hash,
      expires_in: QUERY_PERSISTENCE_TTL
    )
  rescue StandardError => e
    Rails.logger.warn { "QueryPersistence: Cache write failed: #{e.message}" }
  end

  def query_persistence_enabled?
    current_user.present? && request.headers["X-Sec-Purpose"] != "prefetch"
  end
end
