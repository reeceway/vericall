import React, {PropsWithChildren} from 'react';
import {
	AbsoluteFill,
	Easing,
	interpolate,
	spring,
	useCurrentFrame,
	useVideoConfig,
} from 'remotion';

type TransitionVariant = 'slide' | 'fade' | 'none';

export const SceneContainer: React.FC<
	PropsWithChildren<{
		variant?: TransitionVariant;
		background?: string;
		durationInFrames?: number;
	}>
> = ({children, variant = 'fade', background, durationInFrames: sceneDurationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps, durationInFrames} = useVideoConfig();
	const localDuration = sceneDurationInFrames ?? durationInFrames;
	const baseBackground =
		background ?? 'linear-gradient(180deg, #fbfcff 0%, #f3f7fd 100%)';

	if (variant === 'none') {
		return (
			<AbsoluteFill
				style={{
					background: baseBackground,
				}}
			>
				{children}
			</AbsoluteFill>
		);
	}

	const enterProgress = spring({
		fps,
		frame,
		config: {damping: 200, stiffness: 220, mass: 0.8},
		durationInFrames: 18,
	});
	const exitProgress = interpolate(
		frame,
		[Math.max(0, localDuration - 18), localDuration],
		[0, 1],
		{extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)}
	);

	const opacity = interpolate(frame, [0, 12, localDuration - 16, localDuration], [0, 1, 1, 0], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
	});
	const edgePresence = Math.max(
		interpolate(enterProgress, [0, 1], [1, 0], {
			extrapolateLeft: 'clamp',
			extrapolateRight: 'clamp',
		}),
		exitProgress
	);
	const blur =
		variant === 'slide'
			? interpolate(enterProgress + exitProgress, [0, 1], [14, 0], {
					extrapolateLeft: 'clamp',
					extrapolateRight: 'clamp',
			  })
			: interpolate(edgePresence, [0, 1], [0, 10], {
					extrapolateLeft: 'clamp',
					extrapolateRight: 'clamp',
			  });
	const scale =
		variant === 'slide'
			? interpolate(enterProgress + exitProgress, [0, 1], [0.985, 1], {
					extrapolateLeft: 'clamp',
					extrapolateRight: 'clamp',
			  })
			: interpolate(edgePresence, [0, 1], [1, 0.992], {
					extrapolateLeft: 'clamp',
					extrapolateRight: 'clamp',
			  });

	return (
		<AbsoluteFill
			style={{
				background: baseBackground,
				transform: `scale(${scale})`,
				opacity,
				filter: `blur(${blur}px)`,
			}}
		>
			{children}
		</AbsoluteFill>
	);
};
