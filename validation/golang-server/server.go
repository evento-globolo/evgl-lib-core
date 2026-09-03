package servervalidation

import (
	"fmt"
	public "github.com/evento-globolo/evgl-lib-core/validation/golang"
	"github.com/go-playground/validator/v10"
)

var validate = validator.New(validator.WithRequiredStructEnabled())

type TrustedActor struct {
	UserID string `json:"userId" validate:"required,min=1,max=128"`
	TenantID string `json:"tenantId,omitempty" validate:"omitempty,min=1,max=128"`
	Roles []string `json:"roles" validate:"max=64,dive,min=1,max=128"`
}

type ServerRequestContext struct {
	Public public.RequestMeta `json:"public" validate:"required"`
	Actor TrustedActor `json:"actor" validate:"required"`
	SourceIP string `json:"sourceIp,omitempty" validate:"omitempty,ip"`
}

type InternalCommand struct {
	OperationID string `json:"operationId" validate:"required,min=1,max=256"`
	IdempotencyKey string `json:"idempotencyKey,omitempty" validate:"omitempty,min=1,max=128"`
	Context ServerRequestContext `json:"context" validate:"required"`
	Payload any `json:"payload"`
}

func Validate(value any) error {
	if err := validate.Struct(value); err != nil { return fmt.Errorf("server validation failed: %w", err) }
	return nil
}
