import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

export const Scene1Hook: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();

	const line = (start: number) => {
		const local = Math.max(0, frame - start);
		const progress = spring({
			fps,
			frame: local,
			config: {damping: 200, stiffness: 220},
			durationInFrames: 24,
		});
		return {
			opacity: progress,
			transform: `translateY(${interpolate(progress, [0, 1], [24, 0])}px)`,
			filter: `blur(${interpolate(progress, [0, 1], [10, 0])}px)`,
		};
	};

	return (
		<SceneContainer
			durationInFrames={durationInFrames}
			background="linear-gradient(180deg, #fcfdff 0%, #f3f7fd 100%)"
		>
			<div
				style={{
					flex: 1,
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'center',
					padding: '0 220px',
					position: 'relative',
				}}
			>
				<div
					style={{
						position: 'absolute',
						width: 980,
						height: 980,
						borderRadius: '50%',
						background:
							'radial-gradient(circle, rgba(77,124,255,0.12) 0%, rgba(77,124,255,0.05) 28%, rgba(0,0,0,0) 68%)',
						filter: 'blur(26px)',
						opacity: 0.85,
					}}
				/>
				<div
					style={{
						fontFamily: fonts.headline,
						color: colors.text,
						fontWeight: 800,
						fontSize: 64,
						lineHeight: 1.16,
						textAlign: 'center',
						display: 'flex',
						flexDirection: 'column',
						gap: 28,
						position: 'relative',
						zIndex: 1,
					}}
				>
					<div style={line(0)}>
						You&apos;ve seen <span style={{color: colors.accentSoft}}>AI deepfakes</span> fool
						millions online.
					</div>
					<div style={line(75)}>
						Now that same technology is being used to{' '}
						<span style={{color: colors.accentSoft}}>clone voices</span> in real time to{' '}
						<span style={{color: colors.danger}}>steal</span> from businesses like yours.
					</div>
				</div>
			</div>
		</SceneContainer>
	);
};
